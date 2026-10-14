import Foundation
import Testing
@testable import PorterKit

@Suite("Transfer safety")
struct TransferSafetyTests {
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("porter-safety-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item(_ direction: TransferDirection, local: URL, remote: String = "/sdcard/photo.jpg",
                      resolution: ConflictResolution? = nil, modified: Date? = nil) -> TransferItem {
        TransferItem(batchID: UUID(), direction: direction, deviceID: "fake",
            remotePath: RemotePath(remote), localURL: local, displayPath: "photo.jpg",
            totalBytes: 3, sourceModified: modified, conflictResolution: resolution)
    }

    private func run(_ items: [TransferItem], transport: FakeTransport, in root: URL) async throws -> [TransferItem] {
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json"))
        let engine = TransferEngine(queue: queue, resolver: FakeResolver(transport: transport), maximumConcurrency: 3)
        await engine.enqueue(items)
        return try await settle(queue)
    }

    @Test("Flattened and sanitized pull destinations cannot overwrite each other",
          arguments: [("/sdcard/a/photo.jpg", "/sdcard/b/photo.jpg"),
                      ("/sdcard/a/photo:1.jpg", "/sdcard/b/photo∶1.jpg"),
                      ("/sdcard/a/PHOTO.jpg", "/sdcard/b/photo.jpg")])
    func pullCollisions(paths: (String, String)) async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await TransferPlanner().planPull(
            sources: [RemoteFile(path: RemotePath(paths.0), size: 3), RemoteFile(path: RemotePath(paths.1), size: 3)],
            from: FakeTransport(), device: "fake", toLocalDirectory: root, conflicts: FixedConflictResolver(.replace))
        #expect(plan.isBlocked)
        #expect(plan.warnings.contains { if case .destinationCollision = $0 { return true }; return false })
    }

    @Test("FAT sanitization collisions block before either source is uploaded")
    func pushCollision() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = ["photo?.jpg", "photo*.jpg"].map { root.appendingPathComponent($0) }
        for source in sources { try Data([1, 2, 3]).write(to: source) }
        let volume = StorageVolume(id: "card", rawName: "SD card", rootPath: RemotePath("/sdcard"), filesystem: .exfat)
        let plan = try await TransferPlanner().planPush(sources: sources, to: RemotePath("/sdcard"),
            on: FakeTransport(), device: "fake", volume: volume, conflicts: FixedConflictResolver(.keepBoth))
        #expect(plan.isBlocked)
    }

    @Test("Overlapping selections are copied once")
    func duplicateSelection() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = RemoteFile(path: RemotePath("/sdcard/photo.jpg"), size: 3)
        let plan = try await TransferPlanner().planPull(sources: [source, source], from: FakeTransport(),
            device: "fake", toLocalDirectory: root, conflicts: FixedConflictResolver(.replace))
        #expect(!plan.isBlocked && plan.items.count == 1 && plan.totalBytes == 3)
    }

    @Test("Keep Both respects case-insensitive destination names")
    func caseInsensitiveNaming() {
        #expect(ConflictNaming.uniqueName(for: "photo.jpg", existing: ["PHOTO.jpg", "Photo 2.jpg"],
            caseInsensitive: true) == "photo 3.jpg")
    }

    @Test("A file cannot replace a destination folder during planning")
    func folderConflict() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("photo.jpg"), withIntermediateDirectories: true)
        let plan = try await TransferPlanner().planPull(
            sources: [RemoteFile(path: RemotePath("/sdcard/photo.jpg"), size: 3)], from: FakeTransport(),
            device: "fake", toLocalDirectory: root, conflicts: FixedConflictResolver(.replace))
        #expect(plan.isBlocked && plan.items.isEmpty)
    }

    @Test("Unreadable destination metadata fails preflight rather than assuming absence")
    func statFailure() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.jpg")
        try Data([1, 2, 3]).write(to: source)
        let transport = FakeTransport()
        await transport.setFailingStatPaths(["/sdcard/photo.jpg"])
        await #expect(throws: TransferError.permissionDenied(RemotePath("/sdcard/photo.jpg"))) {
            try await TransferPlanner().planPush(sources: [source], to: RemotePath("/sdcard"),
                on: transport, device: "fake", volume: nil, conflicts: FixedConflictResolver(.replace))
        }
    }

    @Test("Each queued item has its own persistent temporary name")
    func uniquePartials() throws {
        let source = URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: 240) + ".jpg")
        let first = item(.pull, local: source)
        let second = item(.pull, local: source)
        #expect(first.localPartialURL != second.localPartialURL)
        #expect(first.remotePartialPath != second.remotePartialPath)
        #expect(first.localPartialURL.lastPathComponent.utf8.count < 255)
        let restored = try JSONDecoder().decode(TransferItem.self, from: JSONEncoder().encode(first))
        #expect(restored.localPartialURL == first.localPartialURL)
    }

    @Test("ADB stat distinguishes missing files, permission failures, disconnects and malformed replies",
          arguments: ["missing", "denied", "offline", "malformed", "present"])
    func adbMetadata(mode: String) async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-adb")
        let reply: String
        switch mode {
        case "missing": reply = "printf '%s\\n' 'stat: /sdcard/photo.jpg: No such file or directory' >&2; exit 1"
        case "denied": reply = "printf '%s\\n' 'stat: /sdcard/photo.jpg: Permission denied' >&2; exit 1"
        case "offline": reply = "printf '%s\\n' 'error: device offline' >&2; exit 1"
        case "malformed": reply = "printf '%s\\n' 'not metadata'"
        default: reply = "printf '%s\\n' '81a4|3|1700000000|/sdcard/photo.jpg'"
        }
        try ("#!/bin/sh\n" + reply + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let transport = ADBTransport(adbURL: executable, serial: "fake",
            device: Device(id: "fake", displayName: "Fake", transport: .adb))
        let path = RemotePath("/sdcard/photo.jpg")
        do {
            let metadata = try await transport.stat(path)
            #expect(mode == "missing" || mode == "present")
            #expect(mode == "missing" ? metadata == nil : metadata?.size == 3)
        } catch let error as TransferError {
            switch (mode, error) {
            case ("denied", .permissionDenied(let denied)): #expect(denied == path)
            case ("offline", .deviceDisconnected), ("malformed", .protocolError): break
            default: Issue.record("Unexpected metadata error: \(error)")
            }
        }
    }

    @Test("Unexpected destinations are preserved at placement", arguments: [TransferDirection.pull, .push])
    func lateConflict(direction: TransferDirection) async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("photo.jpg")
        try Data(direction == .pull ? [9, 9, 9] : [1, 2, 3]).write(to: local)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/photo.jpg", contents: Data(direction == .pull ? [1, 2, 3] : [9, 9, 9]))
        let settled = try await run([item(direction, local: local)], transport: transport, in: root)
        #expect(settled.first?.state == .failed)
        if direction == .pull { #expect(try Data(contentsOf: local) == Data([9, 9, 9])) }
        else { #expect(await transport.contents(of: "/sdcard/photo.jpg") == Data([9, 9, 9])) }
    }

    @Test("Skip is honored again at placement", arguments: [TransferDirection.pull, .push])
    func skipAtPlacement(direction: TransferDirection) async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("photo.jpg")
        try Data(direction == .pull ? [9, 9, 9] : [1, 2, 3]).write(to: local)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/photo.jpg", contents: Data(direction == .pull ? [1, 2, 3] : [9, 9, 9]))
        let transfer = item(direction, local: local, resolution: .skip)
        let settled = try await run([transfer], transport: transport, in: root)
        #expect(settled.first?.state == .skipped)
        if direction == .pull {
            #expect(try Data(contentsOf: local) == Data([9, 9, 9]))
            #expect(!FileManager.default.fileExists(atPath: transfer.localPartialURL.path))
        } else {
            #expect(await transport.contents(of: "/sdcard/photo.jpg") == Data([9, 9, 9]))
            #expect(await transport.contents(of: transfer.remotePartialPath.string) == nil)
        }
    }

    @Test("Replace if Newer rechecks destination dates", arguments: [TransferDirection.pull, .push])
    func newerDestinationIsPreserved(direction: TransferDirection) async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("photo.jpg")
        try Data(direction == .pull ? [9, 9, 9] : [1, 2, 3]).write(to: local)
        let newer = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: local.path)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/photo.jpg", contents: Data(direction == .pull ? [1, 2, 3] : [9, 9, 9]), modified: newer)
        let settled = try await run([item(direction, local: local, resolution: .replaceIfNewer,
            modified: newer.addingTimeInterval(-60))], transport: transport, in: root)
        #expect(settled.first?.state == .skipped)
        if direction == .pull { #expect(try Data(contentsOf: local) == Data([9, 9, 9])) }
        else { #expect(await transport.contents(of: "/sdcard/photo.jpg") == Data([9, 9, 9])) }
    }

    @Test("A successful Replace leaves the verified copy and no backup", arguments: [TransferDirection.pull, .push])
    func successfulReplacement(direction: TransferDirection) async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("photo.jpg")
        try Data(direction == .pull ? [9, 9, 9] : [1, 2, 3]).write(to: local)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/photo.jpg", contents: Data(direction == .pull ? [1, 2, 3] : [9, 9, 9]))
        let settled = try await run([item(direction, local: local, resolution: .replace)], transport: transport, in: root)
        #expect(settled.first?.state == .completed)
        if direction == .pull { #expect(try Data(contentsOf: local) == Data([1, 2, 3])) }
        else {
            #expect(await transport.contents(of: "/sdcard/photo.jpg") == Data([1, 2, 3]))
            #expect(await transport.allPaths() == ["/sdcard/photo.jpg"])
        }
    }

    @Test("A failed phone replacement restores the original")
    func failedReplacement() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("photo.jpg")
        try Data([1, 2, 3]).write(to: local)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/photo.jpg", contents: Data([9, 9, 9]))
        let transfer = item(.push, local: local, resolution: .replace)
        await transport.setFailingMoveSources([transfer.remotePartialPath.string])
        let settled = try await run([transfer], transport: transport, in: root)
        #expect(settled.first?.state == .failed)
        #expect(await transport.contents(of: "/sdcard/photo.jpg") == Data([9, 9, 9]))
        #expect(await transport.allPaths().filter { $0.hasSuffix(".porterbackup") }.isEmpty)
    }

    @Test("Keep Both on the phone preserves contents and original date")
    func pushKeepBoth() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("photo.jpg")
        try Data([1, 2, 3]).write(to: local)
        let originalDate = Date(timeIntervalSince1970: 1_600_000_000)
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/photo.jpg", contents: Data([9, 9, 9]), modified: originalDate)
        let settled = try await run([item(.push, local: local, resolution: .keepBoth, modified: sourceDate)], transport: transport, in: root)
        #expect(settled.first?.state == .completed)
        #expect(await transport.contents(of: "/sdcard/photo.jpg") == Data([9, 9, 9]))
        #expect(await transport.contents(of: "/sdcard/photo 2.jpg") == Data([1, 2, 3]))
        #expect(try await transport.stat(RemotePath("/sdcard/photo.jpg"))?.modified == originalDate)
        #expect(try await transport.stat(RemotePath("/sdcard/photo 2.jpg"))?.modified == sourceDate)
    }

    @Test("A disconnected rollback retains the original backup and reports where to recover it")
    func backupSurvivesRecoveryFailure() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("photo.jpg")
        try Data([1, 2, 3]).write(to: local)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/photo.jpg", contents: Data([9, 9, 9]))
        let transfer = item(.push, local: local, resolution: .replace)
        await transport.setFailingMoveSources([transfer.remotePartialPath.string])
        await transport.setFailsBackupRestoration(true)
        let settled = try await run([transfer], transport: transport, in: root)
        let backup = try #require(await transport.allPaths().first { $0.hasSuffix(".porterbackup") })
        #expect(await transport.contents(of: backup) == Data([9, 9, 9]))
        #expect(settled.first?.state == .failed && settled.first?.errorMessage?.contains(backup) == true)
    }

    @Test("Even a queued Replace cannot delete a Mac folder")
    func queuedFolderIsPreserved() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("photo.jpg")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let valuable = destination.appendingPathComponent("original.txt")
        try Data([9]).write(to: valuable)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/photo.jpg", contents: Data([1, 2, 3]))
        let settled = try await run([item(.pull, local: destination, resolution: .replace)], transport: transport, in: root)
        #expect(settled.first?.state == .failed)
        #expect(try Data(contentsOf: valuable) == Data([9]))
    }

    @Test("Separate queued copies to one destination retain both payloads even with bulk reads")
    func concurrentDestination() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("photo.jpg")
        let transport = FakeTransport()
        await transport.setSupportsBulkPull(true)
        await transport.addFile("/sdcard/a.jpg", contents: Data([1, 2, 3]))
        await transport.addFile("/sdcard/b.jpg", contents: Data([4, 5, 6]))
        let settled = try await run([
            item(.pull, local: local, remote: "/sdcard/a.jpg", resolution: .keepBoth),
            item(.pull, local: local, remote: "/sdcard/b.jpg", resolution: .keepBoth)
        ], transport: transport, in: root)
        #expect(settled.allSatisfy { $0.state == .completed })
        let payloads = try [local, root.appendingPathComponent("photo 2.jpg")].map { try Data(contentsOf: $0) }
        #expect(Set(payloads) == Set([Data([1, 2, 3]), Data([4, 5, 6])]))
    }
}
