import Foundation
import Testing
@testable import PorterKit

@Suite("Photo import")
struct PhotoImportTests {
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("porter-photo-import-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Scanning includes nested photos and optional videos without reading file bytes")
    func mediaScan() async throws {
        let transport = FakeTransport()
        await transport.addFile("/sdcard/DCIM/Camera/IMG.JPG", contents: Data([1, 2]))
        await transport.addFile("/sdcard/DCIM/Camera/clip.MP4", contents: Data([3, 4, 5]))
        await transport.addFile("/sdcard/DCIM/Screenshots/shot.heic", contents: Data([6]))
        await transport.addFile("/sdcard/DCIM/readme.txt", contents: Data([7]))
        await transport.addFile("/sdcard/DCIM/.hidden/secret.jpg", contents: Data([8]))
        await transport.addFile("/sdcard/Pictures/elsewhere.jpg", contents: Data([9]))
        let root = RemotePath("/sdcard/DCIM")
        let scan = try await PhotoImportScanner().scan(root, using: transport)
        #expect(scan.photoCount == 2 && scan.videoCount == 1 && scan.totalBytes == 6)
        #expect(scan.files.count == 3)
        #expect(await transport.readCallCount == 0)
        let photos = try await PhotoImportScanner().scan(root, using: transport, includeVideos: false)
        #expect(photos.photoCount == 2 && photos.videoCount == 0 && photos.totalBytes == 3)
    }

    @Test("Non-files and unsupported extensions cannot be imported as media")
    func fileKinds() {
        #expect(PhotoImportMediaKind.kind(of: RemoteFile(path: RemotePath("/album.jpg"), kind: .directory)) == nil)
        #expect(PhotoImportMediaKind.kind(of: RemoteFile(path: RemotePath("/link.jpg"), kind: .symlink)) == nil)
        #expect(PhotoImportMediaKind.kind(of: RemoteFile(path: RemotePath("/capture.DNG"))) == .photo)
        #expect(PhotoImportMediaKind.kind(of: RemoteFile(path: RemotePath("/clip.webm"))) == .video)
        #expect(PhotoImportMediaKind.kind(of: RemoteFile(path: RemotePath("/notes.txt"))) == nil)
    }

    @Test("Missing and non-directory sources fail with their original paths")
    func unavailableSources() async throws {
        let transport = FakeTransport()
        await transport.addFile("/sdcard/ordinary.jpg", contents: Data([1]))
        await #expect(throws: TransferError.notFound(RemotePath("/sdcard/DCIM"))) {
            try await PhotoImportScanner().scan(RemotePath("/sdcard/DCIM"), using: transport)
        }
        await #expect(throws: TransferError.notADirectory(RemotePath("/sdcard/ordinary.jpg"))) {
            try await PhotoImportScanner().scan(RemotePath("/sdcard/ordinary.jpg"), using: transport)
        }
    }

    @Test("Import selection preserves albums and refreshes changed sizes before planning")
    func selectionAndPaths() async throws {
        let destination = try sandbox()
        defer { try? FileManager.default.removeItem(at: destination) }
        let transport = FakeTransport()
        await transport.addFile("/sdcard/DCIM/Camera/photo.jpg", contents: Data([1]))
        await transport.addFile("/sdcard/DCIM/Other/photo.jpg", contents: Data([2]))
        await transport.addFile("/sdcard/DCIM/Other/ignore.mp4", contents: Data([3]))
        let scan = try await PhotoImportScanner().scan(RemotePath("/sdcard/DCIM"), using: transport)
        await transport.addFile("/sdcard/DCIM/Camera/photo.jpg", contents: Data([4, 5, 6]))
        let paths: Set<RemotePath> = [RemotePath("/sdcard/DCIM/Camera/photo.jpg"), RemotePath("/sdcard/DCIM/Other/photo.jpg")]
        let plan = try await scan.plan(selectedPaths: paths, from: transport, device: "original-phone", to: destination)
        #expect(plan.fileCount == 2 && plan.totalBytes == 4)
        #expect(Set(plan.items.map(\.displayPath)) == ["DCIM/Camera/photo.jpg", "DCIM/Other/photo.jpg"])
        #expect(plan.items.allSatisfy { $0.deviceID == "original-phone" && $0.conflictResolution == .keepBoth })
        #expect(Set(plan.items.map(\.localURL)).count == 2)
    }

    @Test("Skipped existing photos are excluded before copying")
    func skipExisting() async throws {
        let destination = try sandbox()
        defer { try? FileManager.default.removeItem(at: destination) }
        let folder = destination.appendingPathComponent("DCIM/Camera", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([9]).write(to: folder.appendingPathComponent("old.jpg"))
        let transport = FakeTransport()
        await transport.addFile("/sdcard/DCIM/Camera/old.jpg", contents: Data([1, 2]))
        await transport.addFile("/sdcard/DCIM/Camera/new.jpg", contents: Data([3]))
        let scan = try await PhotoImportScanner().scan(RemotePath("/sdcard/DCIM"), using: transport)
        let plan = try await scan.plan(selectedPaths: Set(scan.files.map(\.path)), from: transport, device: "fake",
                                       to: destination, existingFiles: .skip)
        #expect(plan.fileCount == 1 && plan.items.first?.remotePath.name == "new.jpg")
        #expect(try Data(contentsOf: folder.appendingPathComponent("old.jpg")) == Data([9]))
    }

    @Test("A source deleted after scanning fails review instead of producing a partial import")
    func deletedSource() async throws {
        let transport = FakeTransport()
        let photo = RemotePath("/sdcard/DCIM/photo.jpg")
        await transport.addFile(photo.string, contents: Data([1]))
        let scan = try await PhotoImportScanner().scan(RemotePath("/sdcard/DCIM"), using: transport)
        try await transport.remove(photo, recursive: false)
        await #expect(throws: TransferError.notFound(photo)) {
            try await scan.plan(selectedPaths: [photo], from: transport, device: "fake", to: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test("Cancelled scans never return media")
    func cancelledScan() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PhotoImportScanner().scan(RemotePath("/sdcard/DCIM"), using: FakeTransport())
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Names that collide after Mac sanitization fail before writing a shared sidecar")
    func collidingNames() async throws {
        let destination = try sandbox()
        defer { try? FileManager.default.removeItem(at: destination) }
        let transport = FakeTransport()
        await transport.addFile("/sdcard/DCIM/a:b.jpg", contents: Data([1]))
        await transport.addFile("/sdcard/DCIM/a\u{2236}b.jpg", contents: Data([2]))
        let scan = try await PhotoImportScanner().scan(RemotePath("/sdcard/DCIM"), using: transport)
        await #expect(throws: PhotoImportError.collidingNames) {
            try await scan.plan(selectedPaths: Set(scan.files.map(\.path)), from: transport, device: "fake", to: destination)
        }
        #expect(await transport.readCallCount == 0)
    }

    @Test("Import uses the transfer engine's checksum verification and album directories")
    func verifiedImport() async throws {
        let destination = try sandbox()
        defer { try? FileManager.default.removeItem(at: destination) }
        let transport = FakeTransport()
        let path = "/sdcard/DCIM/Camera/photo.jpg", bytes = makePayload(500)
        await transport.addFile(path, contents: bytes)
        let scan = try await PhotoImportScanner().scan(RemotePath("/sdcard/DCIM"), using: transport)
        let plan = try await scan.plan(selectedPaths: Set(scan.files.map(\.path)), from: transport, device: "fake", to: destination)
        let queue = TransferQueue(storeURL: destination.appendingPathComponent("queue.json"))
        let engine = TransferEngine(queue: queue, resolver: FakeResolver(transport: transport))
        await engine.enqueue(plan.items)
        let completed = try await settle(queue)
        #expect(completed.allSatisfy { $0.state == .completed && $0.verifiedChecksum == sha256(bytes) })
        #expect(try Data(contentsOf: destination.appendingPathComponent("DCIM/Camera/photo.jpg")) == bytes)
    }

    @Test("Keep Both protects a file created after review and applies dates to the imported copy")
    func keepBothAfterReview() async throws {
        let destination = try sandbox()
        defer { try? FileManager.default.removeItem(at: destination) }
        let transport = FakeTransport()
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let existingDate = Date(timeIntervalSince1970: 1_600_000_000)
        await transport.addFile("/sdcard/DCIM/photo.jpg", contents: Data([1]), modified: sourceDate)
        let scan = try await PhotoImportScanner().scan(RemotePath("/sdcard/DCIM"), using: transport)
        let plan = try await scan.plan(selectedPaths: Set(scan.files.map(\.path)), from: transport, device: "fake", to: destination)
        let folder = destination.appendingPathComponent("DCIM", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = folder.appendingPathComponent("photo.jpg")
        try Data([9]).write(to: existing)
        try FileManager.default.setAttributes([.modificationDate: existingDate], ofItemAtPath: existing.path)
        let queue = TransferQueue(storeURL: destination.appendingPathComponent("queue.json"))
        let engine = TransferEngine(queue: queue, resolver: FakeResolver(transport: transport))
        await engine.enqueue(plan.items)
        let completed = try await settle(queue)
        #expect(completed.allSatisfy { $0.state == .completed })
        let imported = folder.appendingPathComponent("photo 2.jpg")
        #expect(try Data(contentsOf: existing) == Data([9]))
        #expect(try Data(contentsOf: imported) == Data([1]))
        #expect(try existing.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == existingDate)
        #expect(try imported.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == sourceDate)
    }
}
