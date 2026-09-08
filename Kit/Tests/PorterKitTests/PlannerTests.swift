import Foundation
import Testing
@testable import PorterKit

@Suite("Transfer planning")
struct TransferPlannerTests {

    private func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("porter-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Expands a folder recursively, directories before their contents")
    func recursiveExpansion() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let transport = FakeTransport()
        await transport.addFile("/sdcard/DCIM/Camera/IMG_1.jpg", contents: makePayload(100))
        await transport.addFile("/sdcard/DCIM/Camera/IMG_2.jpg", contents: makePayload(200))
        await transport.addFile("/sdcard/DCIM/readme.txt", contents: makePayload(50))

        let plan = try await TransferPlanner().planPull(
            sources: [RemoteFile(path: RemotePath("/sdcard/DCIM"), kind: .directory)],
            from: transport, device: "fake",
            toLocalDirectory: sandbox,
            conflicts: FixedConflictResolver(.replace)
        )

        #expect(plan.fileCount == 3)
        #expect(plan.totalBytes == 350)
        // Directory placeholders come first, so no file precedes its parent.
        let firstFileIndex = plan.items.firstIndex { !$0.isDirectoryPlaceholder } ?? 0
        let leadingAreAllDirectories = plan.items.prefix(firstFileIndex)
            .allSatisfy { $0.isDirectoryPlaceholder }
        #expect(leadingAreAllDirectories)
        // Paths stay relative to the dragged folder.
        #expect(plan.items.contains { $0.displayPath == "DCIM/Camera/IMG_1.jpg" })
    }

    @Test("Blocks a file too large for a FAT32 card before copying anything")
    func fat32Limit() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let big = sandbox.appendingPathComponent("movie.mkv")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        // Sparse: 5 GiB of address space, a few bytes on disk.
        try handle.truncate(atOffset: 5 * 1024 * 1024 * 1024)
        try handle.close()

        let card = StorageVolume(id: "card", rawName: "SD card", rootPath: RemotePath("/storage/1A2B-3C4D"),
                                 totalBytes: 64_000_000_000, freeBytes: 60_000_000_000,
                                 isRemovable: true, filesystem: .fat32)
        let plan = try await TransferPlanner().planPush(
            sources: [big], to: RemotePath("/storage/1A2B-3C4D"),
            on: FakeTransport(), device: "fake", volume: card,
            conflicts: FixedConflictResolver(.replace)
        )

        #expect(plan.isBlocked)
        #expect(plan.items.isEmpty)
        let warning = try #require(plan.warnings.first)
        #expect(warning.message.contains("FAT32"))
    }

    @Test("Warns when the copy will not fit")
    func insufficientSpace() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let file = sandbox.appendingPathComponent("payload.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 8 * 1024 * 1024 * 1024)
        try handle.close()

        let tiny = StorageVolume(id: "v", rawName: "Internal storage",
                                 rootPath: RemotePath("/sdcard"),
                                 totalBytes: 8_000_000_000, freeBytes: 1_000_000_000)
        let plan = try await TransferPlanner().planPush(
            sources: [file], to: RemotePath("/sdcard/Download"),
            on: FakeTransport(), device: "fake", volume: tiny,
            conflicts: FixedConflictResolver(.replace)
        )

        #expect(plan.isBlocked)
        #expect(plan.warnings.contains { if case .insufficientSpace = $0 { return true }; return false })
    }

    @Test("Renames a file whose name is illegal on the destination and says so")
    func sanitizationIsReported() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let transport = FakeTransport()
        await transport.addFile("/sdcard/Notes/2024: Q1 review.txt", contents: makePayload(10))

        let plan = try await TransferPlanner().planPull(
            sources: [RemoteFile(path: RemotePath("/sdcard/Notes/2024: Q1 review.txt"), size: 10)],
            from: transport, device: "fake", toLocalDirectory: sandbox,
            conflicts: FixedConflictResolver(.replace)
        )

        #expect(plan.items.count == 1)
        #expect(!plan.items[0].localURL.lastPathComponent.contains(":"))
        let renamed = plan.warnings.compactMap { warning -> FilenameSanitizer.Change? in
            if case .renamed(let change) = warning { return change }
            return nil
        }
        #expect(renamed.count == 1)
        #expect(renamed[0].original == "2024: Q1 review.txt")
    }

    @Test("Skip drops the item entirely rather than queueing a no-op")
    func skipRemovesItem() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try Data("existing".utf8).write(to: sandbox.appendingPathComponent("dup.txt"))

        let transport = FakeTransport()
        await transport.addFile("/sdcard/dup.txt", contents: makePayload(10))

        let plan = try await TransferPlanner().planPull(
            sources: [RemoteFile(path: RemotePath("/sdcard/dup.txt"), size: 10)],
            from: transport, device: "fake", toLocalDirectory: sandbox,
            conflicts: FixedConflictResolver(.skip)
        )
        #expect(plan.items.isEmpty)
    }

    @Test("Replace if Newer keeps a destination that is already up to date")
    func replaceIfNewer() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let local = sandbox.appendingPathComponent("sync.txt")
        try Data("newer".utf8).write(to: local)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)], ofItemAtPath: local.path)

        let transport = FakeTransport()
        await transport.addFile("/sdcard/sync.txt", contents: makePayload(10),
                                modified: Date(timeIntervalSince1970: 1_000_000_000))

        let plan = try await TransferPlanner().planPull(
            sources: [RemoteFile(path: RemotePath("/sdcard/sync.txt"), size: 10,
                                 modified: Date(timeIntervalSince1970: 1_000_000_000))],
            from: transport, device: "fake", toLocalDirectory: sandbox,
            conflicts: FixedConflictResolver(.replaceIfNewer)
        )
        #expect(plan.items.isEmpty)
    }

    @Test("Symlinks are skipped and reported, not followed into a loop")
    func symlinksSkipped() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let plan = try await TransferPlanner().planPull(
            sources: [RemoteFile(path: RemotePath("/sdcard"), kind: .symlink,
                                 symlinkTarget: "/storage/self/primary")],
            from: FakeTransport(), device: "fake", toLocalDirectory: sandbox,
            conflicts: FixedConflictResolver(.replace)
        )
        #expect(plan.items.isEmpty)
        #expect(plan.warnings.contains { $0.message.contains("link") })
    }
}

@Suite("Queue persistence")
struct TransferQueueTests {

    private func makeStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("porter-queue-\(UUID()).json")
    }

    @Test("Survives a restart, and never reloads an item as still running")
    func persistence() async throws {
        let store = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: store) }

        let queue = TransferQueue(storeURL: store, saveDebounce: .milliseconds(5))
        let batch = UUID()
        let running = TransferItem(batchID: batch, direction: .pull, deviceID: "fake",
                                   remotePath: RemotePath("/sdcard/a.bin"),
                                   localURL: URL(fileURLWithPath: "/tmp/a.bin"),
                                   displayPath: "a.bin", totalBytes: 100,
                                   bytesTransferred: 40, state: .running)
        let done = TransferItem(batchID: batch, direction: .pull, deviceID: "fake",
                                remotePath: RemotePath("/sdcard/b.bin"),
                                localURL: URL(fileURLWithPath: "/tmp/b.bin"),
                                displayPath: "b.bin", totalBytes: 100,
                                bytesTransferred: 100, state: .completed)
        await queue.append([running, done])
        await queue.flush()

        let reloaded = TransferQueue(storeURL: store)
        await reloaded.load()
        let items = await reloaded.orderedItems

        #expect(items.count == 2)
        // Nothing is running after a relaunch, whatever the manifest recorded.
        #expect(items[0].state == .queued)
        #expect(items[0].bytesTransferred == 40)   // the resume point is kept
        #expect(items[1].state == .completed)
    }

    @Test("Hands out queued work in order and skips what is already running")
    func ordering() async throws {
        let store = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: store) }
        let queue = TransferQueue(storeURL: store, saveDebounce: .milliseconds(5))

        let items = (0..<3).map { index in
            TransferItem(batchID: UUID(), direction: .pull, deviceID: "fake",
                         remotePath: RemotePath("/sdcard/\(index).bin"),
                         localURL: URL(fileURLWithPath: "/tmp/\(index).bin"),
                         displayPath: "\(index).bin", totalBytes: 10)
        }
        await queue.append(items)

        #expect(await queue.nextQueued(excluding: [])?.id == items[0].id)
        #expect(await queue.nextQueued(excluding: [items[0].id])?.id == items[1].id)
        await queue.update(items[1].id) { $0.state = .completed }
        #expect(await queue.nextQueued(excluding: [items[0].id])?.id == items[2].id)
    }

    @Test("Clearing finished work keeps the failures the user still needs")
    func clearCompleted() async throws {
        let store = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: store) }
        let queue = TransferQueue(storeURL: store, saveDebounce: .milliseconds(5))

        let done = TransferItem(batchID: UUID(), direction: .pull, deviceID: "fake",
                                remotePath: RemotePath("/a"), localURL: URL(fileURLWithPath: "/tmp/a"),
                                displayPath: "a", totalBytes: 1, state: .completed)
        let failed = TransferItem(batchID: UUID(), direction: .pull, deviceID: "fake",
                                  remotePath: RemotePath("/b"), localURL: URL(fileURLWithPath: "/tmp/b"),
                                  displayPath: "b", totalBytes: 1, state: .failed)
        await queue.append([done, failed])
        await queue.clearCompleted()

        let remaining = await queue.orderedItems
        #expect(remaining.count == 1)
        #expect(remaining[0].state == .failed)
    }

    @Test("Aggregate progress counts completed items at full size")
    func summary() async throws {
        let store = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: store) }
        let queue = TransferQueue(storeURL: store, saveDebounce: .milliseconds(5))

        await queue.append([
            TransferItem(batchID: UUID(), direction: .pull, deviceID: "fake", remotePath: RemotePath("/a"),
                         localURL: URL(fileURLWithPath: "/tmp/a"), displayPath: "a",
                         totalBytes: 1000, state: .completed),
            TransferItem(batchID: UUID(), direction: .pull, deviceID: "fake", remotePath: RemotePath("/b"),
                         localURL: URL(fileURLWithPath: "/tmp/b"), displayPath: "b",
                         totalBytes: 1000, bytesTransferred: 250, state: .running)
        ])

        let summary = await queue.summary(bytesPerSecond: 500, estimatedTimeRemaining: nil, isPaused: false)
        #expect(summary.totalBytes == 2000)
        #expect(summary.transferredBytes == 1250)
        #expect(summary.completedItems == 1)
        #expect(summary.isRunning)
        #expect(abs(summary.fractionComplete - 0.625) < 0.001)
    }
}
