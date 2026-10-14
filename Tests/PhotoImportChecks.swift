import Foundation
import PorterKit

private struct PhotoImportCheckFailed: Error { let message: String }

private actor ImportResolverGate: TransportResolver {
    let transport: FakeTransport
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private var isOpen = false

    init(transport: FakeTransport) { self.transport = transport }
    func transport(for deviceID: DeviceID) async throws -> any DeviceTransport {
        entered = true
        if !isOpen { await withCheckedContinuation { waiter = $0 } }
        return transport
    }
    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
enum PhotoImportChecks {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw PhotoImportCheckFailed(message: message) }
    }

    static func run(in root: URL) async throws -> Int {
        let destination = root.appendingPathComponent("Photo import destination", isDirectory: true)
        let otherDestination = root.appendingPathComponent("Other photo import destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDestination, withIntermediateDirectories: true)
        let phone = Device(id: "original-phone", displayName: "Original phone", transport: .adb)
        let volume = StorageVolume(id: "internal", rawName: "Internal", rootPath: RemotePath("/sdcard"))
        let transport = FakeTransport()
        let photo = RemotePath("/sdcard/DCIM/Camera/photo.jpg")
        await transport.addFile(photo.string, contents: Data([1]))
        await transport.addFile("/sdcard/DCIM/Camera/video.mp4", contents: Data([2, 3]))
        await transport.addFile("/sdcard/Pictures/picture.png", contents: Data([4]))
        let session = PhotoImportSession(device: phone, volume: volume, currentFolder: RemotePath("/sdcard/Pictures"),
                                        destination: destination, resolver: FakeResolver(transport: transport))
        await session.scan()
        try check(session.scanResult?.files.count == 2 && session.selectedPaths.count == 2
                  && session.selectedBytes == 3 && !session.isWorking, "Scanning failed to select the available media")
        session.selectedPaths = [photo.string]
        await transport.addFile(photo.string, contents: Data([5, 6, 7]))
        await session.review()
        try check(session.reviewedPlan?.fileCount == 1 && session.reviewedPlan?.totalBytes == 3
                  && session.reviewedPlan?.items.first?.deviceID == phone.id
                  && session.reviewedPlan?.items.first?.localURL == destination.appendingPathComponent("DCIM/Camera/photo.jpg"),
                  "Review changed the source phone, selection, destination, or used stale sizes")
        try check(await transport.readCallCount == 0, "Scanning or reviewing downloaded file bytes")
        var passed = 1

        session.destination = otherDestination
        try check(session.reviewedPlan == nil && session.scanResult != nil && session.selectedPaths == [photo.string],
                  "Changing the destination kept an obsolete review or discarded the scan")
        await session.review()
        session.existingFiles = .skip
        try check(session.reviewedPlan == nil, "Changing conflict policy kept an obsolete import plan")
        await session.review()
        session.selectedPaths = []
        try check(session.reviewedPlan == nil, "Changing the selection kept an obsolete import plan")
        passed += 1

        session.source = .pictures
        try check(session.scanResult == nil && session.selectedPaths.isEmpty && session.sourcePath == RemotePath("/sdcard/Pictures"),
                  "Changing the import source retained old files")
        await session.scan()
        try check(session.scanResult?.photoCount == 1, "The Pictures source did not scan its own folder")
        session.source = .currentFolder
        try check(session.sourcePath == session.currentFolder, "Current-folder import changed its captured source")
        session.source = .camera
        session.includeVideos = false
        await session.scan()
        try check(session.scanResult?.photoCount == 1 && session.scanResult?.videoCount == 0,
                  "Turning off videos kept the previous video selection")
        passed += 1

        try await transport.remove(photo, recursive: false)
        await session.review()
        try check(session.reviewedPlan == nil && session.errorMessage?.contains("photo.jpg") == true && !session.isWorking,
                  "A deleted source left a stale review or did not report its path")
        try await transport.createDirectory(photo)
        await session.review()
        try check(session.reviewedPlan == nil && session.errorMessage?.contains("no longer a photo or video") == true,
                  "An import source replaced by a folder was still accepted")
        passed += 1

        let gate = ImportResolverGate(transport: transport)
        let delayed = PhotoImportSession(device: phone, volume: volume, currentFolder: RemotePath("/sdcard/Pictures"),
                                        destination: destination, resolver: gate)
        let oldScan = Task { await delayed.scan() }
        for _ in 0..<1000 {
            if await gate.entered { break }
            await Task.yield()
        }
        try check(await gate.entered, "Delayed scan did not start")
        delayed.source = .pictures
        await gate.open()
        await oldScan.value
        try check(delayed.scanResult == nil && delayed.selectedPaths.isEmpty && !delayed.isWorking,
                  "An obsolete source scan published stale results")
        await delayed.scan()
        try check(delayed.scanResult?.root == RemotePath("/sdcard/Pictures") && delayed.scanResult?.files.count == 1,
                  "A new scan could not start after discarding the obsolete scan")
        passed += 1

        let cancelGate = ImportResolverGate(transport: transport)
        let cancelled = PhotoImportSession(device: phone, volume: volume, currentFolder: RemotePath("/sdcard/Pictures"),
                                          destination: destination, resolver: cancelGate)
        let pending = Task { await cancelled.scan() }
        for _ in 0..<1000 {
            if await cancelGate.entered { break }
            await Task.yield()
        }
        try check(await cancelGate.entered, "Cancellable scan did not start")
        pending.cancel()
        cancelled.cancelWork()
        await cancelGate.open()
        await pending.value
        try check(cancelled.scanResult == nil && cancelled.errorMessage == nil && !cancelled.isWorking,
                  "Cancelling a scan retained a result or left the session busy")
        passed += 1

        await delayed.review()
        try check(delayed.reviewedPlan?.fileCount == 1,
                  "The disconnected-phone check could not prepare an import: \(delayed.errorMessage ?? "no error"), selected: \(delayed.selectedPaths.count), working: \(delayed.isWorking)")
        try check(delayed.reviewedPlan?.isBlocked == false && !delayed.isWorking,
                  "The disconnected-phone fixture is blocked: \(delayed.reviewedPlan?.warnings.map(\.message) ?? []), working: \(delayed.isWorking)")
        let model = AppModel()
        let queued = await model.enqueuePhotoImport(delayed)
        let queue = await model.engine.queue
        let items = await queue.orderedItems
        try check(!queued && delayed.errorMessage?.contains("Reconnect") == true
                  && items.isEmpty,
                  "Disconnected-phone import returned \(queued), error: \(delayed.errorMessage ?? "none"), queued items: \(items.count)")
        passed += 1
        return passed
    }
}
