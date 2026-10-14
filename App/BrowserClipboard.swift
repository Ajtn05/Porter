import AppKit
import Observation
import PorterKit

@MainActor
protocol BrowserPasteboard {
    var changeCount: Int { get }
    func availableType(from types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType?
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func fileURLs() -> [URL]
    @discardableResult func clearContents() -> Int
    @discardableResult func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
    @discardableResult func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: BrowserPasteboard {
    func fileURLs() -> [URL] {
        (readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

@MainActor
@Observable
final class BrowserClipboard {
    static let remoteFilesType = NSPasteboard.PasteboardType("app.porter.remote-files")

    enum Contents {
        case local([URL])
        case remote(RemoteFileDrag)
    }

    private(set) var contents: Contents?
    private let pasteboard: any BrowserPasteboard
    private var changeCount = -1

    init(pasteboard: any BrowserPasteboard = NSPasteboard.general) {
        self.pasteboard = pasteboard
        refresh()
    }

    func refresh() {
        guard changeCount != pasteboard.changeCount else { return }
        changeCount = pasteboard.changeCount
        contents = nil
        if pasteboard.availableType(from: [Self.remoteFilesType]) != nil {
            guard let data = pasteboard.data(forType: Self.remoteFilesType),
                  let payload = try? JSONDecoder().decode(RemoteFileDrag.self, from: data),
                  !payload.deviceID.isEmpty, !payload.paths.isEmpty,
                  payload.paths.allSatisfy({ path in
                      path.hasPrefix("/") && !RemotePath(path).isRoot
                          && !path.split(separator: "/").contains("..")
                  }) else { return }
            contents = .remote(payload)
        } else {
            let urls = pasteboard.fileURLs()
            if !urls.isEmpty { contents = .local(urls) }
        }
    }

    func copy(_ urls: [URL]) {
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        refresh()
    }

    func copy(_ payload: RemoteFileDrag) {
        guard !payload.paths.isEmpty, let data = try? JSONEncoder().encode(payload) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.remoteFilesType)
        refresh()
    }

    func pasteRequest(in pane: BrowserPane, localDirectory: URL, devicePath: RemotePath,
                      selectedDevice: Device?, selectedVolume: StorageVolume?,
                      devices: [Device], isLoadingDevice: Bool, includeHidden: Bool) -> BrowserPasteRequest? {
        switch (pane, contents) {
        case (.mac, .remote(let payload)):
            guard let device = devices.first(where: { $0.id.rawValue == payload.deviceID }),
                  device.readiness.isBrowsable else { return nil }
            return .pull(paths: payload.paths.map(RemotePath.init), deviceID: device.id,
                         destination: localDirectory, includeHidden: includeHidden)
        case (.android, .local(let urls)):
            guard !isLoadingDevice, let device = selectedDevice, device.readiness.isBrowsable,
                  let volume = selectedVolume, devicePath.relative(to: volume.rootPath) != nil else { return nil }
            return .push(urls: urls, deviceID: device.id, destination: devicePath,
                         volume: volume, includeHidden: includeHidden)
        default: return nil
        }
    }
}

enum BrowserPasteRequest: Sendable {
    case pull(paths: [RemotePath], deviceID: DeviceID, destination: URL, includeHidden: Bool)
    case push(urls: [URL], deviceID: DeviceID, destination: RemotePath, volume: StorageVolume, includeHidden: Bool)

    var deviceID: DeviceID {
        switch self {
        case .pull(_, let deviceID, _, _), .push(_, let deviceID, _, _, _): return deviceID
        }
    }

    func plan(using transport: any DeviceTransport, conflicts: any ConflictResolving) async throws -> TransferPlan {
        switch self {
        case .pull(let paths, let deviceID, let destination, let includeHidden):
            var files: [RemoteFile] = []
            var seen: Set<RemotePath> = []
            // Clipboard paths outlive folder visits and metadata snapshots.
            // Re-stat before planning so changed sizes and deleted sources are
            // handled before any bytes move.
            for path in paths where seen.insert(path).inserted {
                try Task.checkCancellation()
                guard let file = try await transport.stat(path) else { throw TransferError.notFound(path) }
                files.append(file)
            }
            return try await TransferPlanner().planPull(
                sources: files, from: transport, device: deviceID, toLocalDirectory: destination,
                conflicts: conflicts, includeHidden: includeHidden
            )
        case .push(let urls, let deviceID, let destination, let volume, let includeHidden):
            return try await TransferPlanner().planPush(
                sources: urls, to: destination, on: transport, device: deviceID, volume: volume,
                conflicts: conflicts, includeHidden: includeHidden
            )
        }
    }
}
