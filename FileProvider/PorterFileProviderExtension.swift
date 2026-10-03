import FileProvider
import Foundation

/// A read-only Finder surface for one Android device. The extension is
/// intentionally transport-free: all metadata and byte requests cross the
/// App-Group bridge before they reach ADB or MTP.
final class PorterFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let client = PorterFileProviderClient()
    private let store: PorterFileProviderItemStore

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.store = PorterFileProviderItemStore(domain: domain)
        super.init()
        Self.removeAbandonedTemporaryFiles(domainIdentifier: domain.identifier.rawValue)
    }

    func invalidate() {}

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        if identifier == .rootContainer {
            completionHandler(PorterFileProviderItem.root(named: domain.displayName), nil)
            progress.completedUnitCount = 1
            return progress
        }

        guard let record = store.record(for: identifier) else {
            completionHandler(nil, noSuchItemError())
            return progress
        }
        completionHandler(PorterFileProviderItem(record: record), nil)
        progress.completedUnitCount = 1
        return progress
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let record = store.record(for: itemIdentifier), !record.isDirectory else {
            let progress = Progress(totalUnitCount: 1)
            completionHandler(nil, nil, noSuchItemError())
            return progress
        }
        let progress = Progress(totalUnitCount: max(record.size, 1))

        let client = client
        let store = store
        let domainIdentifier = domain.identifier.rawValue
        let completionHandler = PorterUncheckedSendable(value: completionHandler)
        let progressBox = PorterUncheckedSendable(value: progress)
        let task = Task { @MainActor [client, store, domainIdentifier, record, completionHandler, progressBox] in
            var sharedURL: URL?
            var outputURL: URL?
            do {
                let response = try await client.send(
                    .download(domainIdentifier: domainIdentifier, path: record.path),
                    timeout: 60 * 60,
                    progress: { bytes in
                        progressBox.value.completedUnitCount = min(
                            max(bytes, 0), progressBox.value.totalUnitCount
                        )
                    }
                )
                guard case .downloadedFile(let name, let size) = response,
                      let identifier = UUID(uuidString: name),
                      identifier.uuidString == name, size >= 0,
                      let directories = PorterFileProviderFileBridge.directories() else {
                    throw PorterFileProviderBridgeError.invalidResponse
                }
                let source = directories.downloads.appendingPathComponent(name)
                sharedURL = source
                let temporaryDirectory = try Self.temporaryDirectory(domainIdentifier: domainIdentifier)
                let destination = temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.moveItem(at: source, to: destination)
                sharedURL = nil
                outputURL = destination
                try Task.checkCancellation()
                let actualSize = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size]
                                  as? NSNumber)?.int64Value
                guard actualSize == size else { throw PorterFileProviderBridgeError.invalidResponse }
                var updatedRecord = record
                updatedRecord.size = size
                _ = store.record([updatedRecord])
                progressBox.value.completedUnitCount = progressBox.value.totalUnitCount
                completionHandler.value(destination, PorterFileProviderItem(record: updatedRecord), nil)
            } catch is CancellationError {
                if let sharedURL { try? FileManager.default.removeItem(at: sharedURL) }
                if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
                completionHandler.value(
                    nil,
                    nil,
                    NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                )
            } catch {
                if let sharedURL { try? FileManager.default.removeItem(at: sharedURL) }
                if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
                completionHandler.value(nil, nil, fileProviderError(for: error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields,
                    contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, unsupportedError())
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, unsupportedError())
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(unsupportedError())
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        PorterFileProviderEnumerator(
            domainIdentifier: domain.identifier.rawValue,
            containerItemIdentifier: containerItemIdentifier,
            client: client,
            store: store
        )
    }

    private static func temporaryDirectory(domainIdentifier: String) throws -> URL {
        // The manager's temporary location is on the same volume as the
        // Finder-visible file, which lets File Provider clone and unlink it.
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: domainIdentifier),
            displayName: "Porter"
        )
        guard let manager = NSFileProviderManager(for: domain) else {
            throw PorterFileProviderBridgeError.hostUnavailable
        }
        let directory = try manager.temporaryDirectoryURL()
            .appendingPathComponent("PorterDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func removeAbandonedTemporaryFiles(domainIdentifier: String) {
        guard let directory = try? temporaryDirectory(domainIdentifier: domainIdentifier),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for file in files {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
