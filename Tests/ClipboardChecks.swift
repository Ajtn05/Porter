import AppKit
import PorterKit

private struct ClipboardCheckFailed: Error { let message: String }

// The outer workspace sandbox cannot contact the macOS pasteboard service.
// Local AppKit items retain the same representations without that service.
@MainActor
private final class MemoryBrowserPasteboard: BrowserPasteboard {
    private(set) var changeCount = 0
    private var items: [NSPasteboardItem] = []

    func availableType(from types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        types.first { type in items.contains { $0.types.contains(type) } }
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? { items.first?.data(forType: type) }

    func fileURLs() -> [URL] {
        items.compactMap { item in
            guard let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL else { return nil }
            return url
        }
    }

    @discardableResult func clearContents() -> Int {
        items = []
        changeCount += 1
        return changeCount
    }

    @discardableResult func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        items = objects.map { object in
            if let item = object as? NSPasteboardItem { return item }
            let item = NSPasteboardItem()
            if let value = object.pasteboardPropertyList(forType: .fileURL) as? String {
                item.setString(value, forType: .fileURL)
            }
            return item
        }
        changeCount += 1
        return !items.isEmpty
    }

    @discardableResult func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool {
        guard let data else { return false }
        let item = NSPasteboardItem()
        item.setData(data, forType: type)
        return writeObjects([item])
    }

    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) {
        let item = NSPasteboardItem()
        item.setString(string, forType: type)
        writeObjects([item])
    }
}

@MainActor
enum ClipboardChecks {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw ClipboardCheckFailed(message: message) }
    }

    static func run(in root: URL) async throws -> Int {
        let manager = FileManager.default
        let source = root.appendingPathComponent("Clipboard sources", isDirectory: true)
        let folder = source.appendingPathComponent("Trip photos", isDirectory: true)
        let photo = source.appendingPathComponent("café photo.jpg")
        let nested = folder.appendingPathComponent("trip.jpg")
        let destination = root.appendingPathComponent("Clipboard destination", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: photo)
        try Data([4, 5]).write(to: nested)

        let pasteboard = MemoryBrowserPasteboard()
        let clipboard = BrowserClipboard(pasteboard: pasteboard)
        let phone = Device(id: "source-phone", displayName: "Source phone", transport: .adb)
        let otherPhone = Device(id: "other-phone", displayName: "Other phone", transport: .mtp)
        let volume = StorageVolume(id: "internal", rawName: "Internal storage", rootPath: RemotePath("/storage/emulated/0"),
                                   freeBytes: 1_000_000_000, filesystem: .ext4)
        let targetPath = volume.rootPath.appending("Pictures")

        func request(_ pane: BrowserPane, devices: [Device] = [phone],
                     selected: Device? = phone, selectedVolume: StorageVolume? = volume,
                     loading: Bool = false, path: RemotePath = targetPath) -> BrowserPasteRequest? {
            clipboard.pasteRequest(in: pane, localDirectory: destination, devicePath: path,
                selectedDevice: selected, selectedVolume: selectedVolume, devices: devices,
                isLoadingDevice: loading, includeHidden: true)
        }

        // Regression: Finder's standard file URLs must remain usable after a
        // pane navigation clears the selection that was originally copied.
        try check(pasteboard.writeObjects([photo as NSURL, folder as NSURL]),
                  "The isolated test pasteboard rejected file URLs (change count: \(pasteboard.changeCount))")
        clipboard.refresh()
        guard case .push(let finderURLs, let destinationDevice, let remoteDestination, _, _) = request(.android) else {
            throw ClipboardCheckFailed(message: "Finder file URLs did not enable an Android paste")
        }
        try check(Set(finderURLs) == [photo, folder] && destinationDevice == phone.id && remoteDestination == targetPath,
                  "Finder paste lost its sources or destination")
        let model = AppModel(clipboard: clipboard)
        model.localDirectory = source
        model.refreshLocalPane()
        model.localSelection = [photo.path, folder.path]
        model.copySelectionToClipboard(in: .mac)
        model.open(localDirectory: destination)
        guard case .local(let copiedURLs) = clipboard.contents else {
            throw ClipboardCheckFailed(message: "Mac Copy did not publish standard file URLs")
        }
        let exported = pasteboard.fileURLs()
        try check(Set(copiedURLs) == [photo, folder] && Set(exported) == Set(copiedURLs)
                  && model.localSelection.isEmpty, "Mac navigation changed the copied selection or broke Finder compatibility")

        try check(request(.mac) == nil && request(.android, loading: true) == nil
                  && request(.android, selected: nil) == nil && request(.android, selectedVolume: nil) == nil
                  && request(.android, path: RemotePath("/another-volume")) == nil,
                  "Paste accepted an unsupported pane, loading phone, or invalid storage destination")
        var offline = phone
        offline.readiness = .offline
        try check(request(.android, selected: offline) == nil, "Paste accepted an offline destination phone")

        let transport = FakeTransport()
        await transport.addFile(targetPath.appending(photo.lastPathComponent).string, contents: Data([9]))
        guard let upload = request(.android) else { throw ClipboardCheckFailed(message: "Local clipboard was lost") }
        let pushPlan = try await upload.plan(using: transport, conflicts: FixedConflictResolver(.keepBoth))
        try check(pushPlan.fileCount == 2 && pushPlan.items.contains(where: { $0.isDirectoryPlaceholder })
                  && pushPlan.items.allSatisfy { $0.deviceID == phone.id && $0.direction == .push }
                  && pushPlan.items.contains(where: { $0.localURL == photo && $0.remotePath != targetPath.appending(photo.lastPathComponent) }),
                  "Clipboard upload bypassed folder expansion or Keep Both conflict handling")

        let remotePhoto = RemotePath("/DCIM/café photo.jpg")
        let remoteFolder = RemotePath("/DCIM/Trip photos")
        let copiedPaths = [remotePhoto.string, remoteFolder.string, remotePhoto.string]
        clipboard.copy(RemoteFileDrag(deviceID: phone.id.rawValue, paths: copiedPaths))
        guard let download = request(.mac, devices: [phone, otherPhone], selected: otherPhone) else {
            throw ClipboardCheckFailed(message: "Phone clipboard was tied to the currently selected phone")
        }
        try check(download.deviceID == phone.id && request(.android) == nil
                  && request(.mac, devices: [otherPhone], selected: otherPhone) == nil
                  && request(.mac, devices: [offline]) == nil,
                  "Phone paste switched its source phone or accepted a disconnected source")
        await transport.addFile(remotePhoto.string, contents: Data([6, 7, 8, 9]))
        await transport.addFile(remoteFolder.appending("trip.jpg").string, contents: Data([10, 11]))
        try Data([12]).write(to: destination.appendingPathComponent(remotePhoto.name))
        let pullPlan = try await download.plan(using: transport, conflicts: FixedConflictResolver(.skip))
        try check(pullPlan.fileCount == 1 && pullPlan.items.count == 2
                  && pullPlan.items.allSatisfy { $0.deviceID == phone.id && $0.direction == .pull }
                  && pullPlan.items.allSatisfy { $0.localURL.path.hasPrefix(destination.path + "/") },
                  "Phone paste bypassed recursive planning, destination capture, or Skip conflicts")
        try manager.removeItem(at: destination.appendingPathComponent(remotePhoto.name))
        let freshPlan = try await download.plan(using: transport, conflicts: FixedConflictResolver(.replace))
        try check(freshPlan.fileCount == 2 && freshPlan.totalBytes == 6,
                  "Phone paste used stale sizes or scheduled a duplicate clipboard path")
        try await transport.remove(remotePhoto, recursive: false)
        do {
            _ = try await download.plan(using: transport, conflicts: FixedConflictResolver(.replace))
            throw ClipboardCheckFailed(message: "A deleted clipboard source produced a partial plan")
        } catch TransferError.notFound(let path) {
            try check(path == remotePhoto, "Deleted source error lost the copied path")
        }

        // Regression: activating Porter after another app replaces the
        // clipboard must discard the previous phone payload.
        pasteboard.clearContents()
        pasteboard.setString("ordinary text", forType: .string)
        clipboard.refresh()
        try check(clipboard.contents == nil && request(.mac) == nil && request(.android) == nil,
                  "Replacing the clipboard left stale files available for Paste")
        for paths in [[], ["relative.jpg"], ["/"], ["/DCIM/../private.jpg"]] {
            pasteboard.clearContents()
            pasteboard.setData(try JSONEncoder().encode(RemoteFileDrag(deviceID: phone.id.rawValue, paths: paths)),
                               forType: BrowserClipboard.remoteFilesType)
            clipboard.refresh()
            try check(clipboard.contents == nil, "An invalid phone clipboard payload was accepted")
        }
        pasteboard.clearContents()
        pasteboard.setData(Data("invalid JSON".utf8), forType: BrowserClipboard.remoteFilesType)
        clipboard.refresh()
        try check(clipboard.contents == nil, "Malformed phone clipboard data was accepted")
        return 8
    }
}
