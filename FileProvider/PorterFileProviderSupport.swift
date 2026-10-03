import FileProvider
import Foundation

/// Each request gets a private App-Group reply file, so calls can safely cross
/// the File Provider callback-to-task boundary without exposing a transport.
final class PorterFileProviderClient: @unchecked Sendable {
    func send(_ request: PorterFileProviderRequest,
              timeout: TimeInterval = 30,
              progress: (@Sendable (Int64) -> Void)? = nil) async throws -> PorterFileProviderResponse {
        guard let directories = PorterFileProviderFileBridge.directories() else {
            throw PorterFileProviderBridgeError.hostUnavailable
        }

        let requestID = UUID().uuidString
        let requestData = try JSONEncoder().encode(request)
        let requestURL = directories.requests.appendingPathComponent("\(requestID).json")
        let responseURL = directories.responses.appendingPathComponent("\(requestID).json")
        let cancellationURL = directories.cancellations.appendingPathComponent(requestID)
        let progressURL = directories.progress.appendingPathComponent(requestID)
        try requestData.write(to: requestURL, options: .atomic)
        var completed = false
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: responseURL)
            try? FileManager.default.removeItem(at: progressURL)
            if !completed {
                FileManager.default.createFile(atPath: cancellationURL.path, contents: nil)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let progress,
               let bytes = try? Data(contentsOf: progressURL),
               let count = Int64(String(decoding: bytes, as: UTF8.self)) {
                progress(count)
            }
            if let data = try? Data(contentsOf: responseURL) {
                let reply = try JSONDecoder().decode(PorterFileProviderBridgeReply.self, from: data)
                if let errorDescription = reply.errorDescription {
                    throw PorterFileProviderBridgeError.hostFailed(errorDescription)
                }
                guard let responseData = reply.responseData,
                      let response = try? JSONDecoder().decode(PorterFileProviderResponse.self, from: responseData) else {
                    throw PorterFileProviderBridgeError.invalidResponse
                }
                completed = true
                return response
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw PorterFileProviderBridgeError.hostUnavailable
    }
}

/// Access to the cache is serialized by `lock`, including persistence.
final class PorterFileProviderItemStore: @unchecked Sendable {
    struct Changes {
        let updated: [PorterFileProviderRecord]
        let deleted: [NSFileProviderItemIdentifier]
        let anchor: NSFileProviderSyncAnchor
    }

    private struct State: Codable {
        var records: [String: PorterFileProviderRecord] = [:]
        var snapshots: [String: [String: PorterFileProviderRecord]] = [:]
        var anchors: [String: String] = [:]
    }

    private let lock = NSLock()
    private var state: State
    private let storeURL: URL?

    init(domain: NSFileProviderDomain) {
        // `stateDirectoryURL` is reserved for external-volume providers. A
        // regular replicated provider keeps its small metadata cache in the
        // document group shared with its host app instead.
        let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PorterFileProviderConfiguration.documentGroup
        )?.appendingPathComponent("FileProviderState", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.storeURL = directory?.appendingPathComponent(
            "\(domain.identifier.rawValue)-items.json",
            isDirectory: false
        )
        if let storeURL,
           let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            self.state = decoded
        } else if let storeURL,
                  let data = try? Data(contentsOf: storeURL),
                  let oldRecords = try? JSONDecoder().decode([String: PorterFileProviderRecord].self, from: data) {
            self.state = State(records: oldRecords)
        } else {
            self.state = State()
        }
    }

    func record(for identifier: NSFileProviderItemIdentifier) -> PorterFileProviderRecord? {
        lock.withLock { state.records[identifier.rawValue] }
    }

    func allRecords() -> [PorterFileProviderRecord] {
        lock.withLock { Array(state.records.values) }
    }

    func record(_ newRecords: [PorterFileProviderRecord]) -> [PorterFileProviderRecord] {
        lock.withLock {
            for record in newRecords {
                state.records[PorterFileProviderItemIdentifier.item(for: record.path).rawValue] = record
            }
            persist()
            return newRecords
        }
    }

    func anchor(for container: NSFileProviderItemIdentifier) -> NSFileProviderSyncAnchor {
        lock.withLock { anchorWithoutLock(for: container) }
    }

    func replaceItems(_ records: [PorterFileProviderRecord],
                      in container: NSFileProviderItemIdentifier) {
        lock.withLock {
            let key = container.rawValue
            let newSnapshot = Dictionary(records.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
            let oldSnapshot = state.snapshots[key] ?? [:]
            state.snapshots[key] = newSnapshot
            for path in oldSnapshot.keys where newSnapshot[path] == nil {
                removeRecordIfUnreferenced(path)
            }
            for record in records {
                state.records[PorterFileProviderItemIdentifier.item(for: record.path).rawValue] = record
            }
            persist()
        }
    }

    func changes(_ records: [PorterFileProviderRecord],
                 in container: NSFileProviderItemIdentifier,
                 from anchor: NSFileProviderSyncAnchor) -> Changes? {
        lock.withLock {
            guard anchor == anchorWithoutLock(for: container) else { return nil }
            let key = container.rawValue
            let oldSnapshot = state.snapshots[key] ?? [:]
            let newSnapshot = Dictionary(records.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
            let updated = records.filter { oldSnapshot[$0.path] != $0 }
            let deleted = oldSnapshot.keys.filter { newSnapshot[$0] == nil }
                .map(PorterFileProviderItemIdentifier.item(for:))
            state.snapshots[key] = newSnapshot
            for path in oldSnapshot.keys where newSnapshot[path] == nil {
                removeRecordIfUnreferenced(path)
            }
            for record in records {
                state.records[PorterFileProviderItemIdentifier.item(for: record.path).rawValue] = record
            }
            if !updated.isEmpty || !deleted.isEmpty {
                state.anchors[key] = UUID().uuidString
            }
            let currentAnchor = anchorWithoutLock(for: container)
            persist()
            return Changes(updated: updated, deleted: deleted, anchor: currentAnchor)
        }
    }

    private func anchorWithoutLock(for container: NSFileProviderItemIdentifier) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data((state.anchors[container.rawValue] ?? "porter-initial").utf8))
    }

    private func removeRecordIfUnreferenced(_ path: String) {
        guard !state.snapshots.contains(where: { key, snapshot in
            key != NSFileProviderItemIdentifier.workingSet.rawValue && snapshot[path] != nil
        }) else { return }
        let identifier = PorterFileProviderItemIdentifier.item(for: path).rawValue
        if state.records[identifier]?.isDirectory == true {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let descendants = state.records.values.filter { $0.path.hasPrefix(prefix) }
            for descendant in descendants {
                let childID = PorterFileProviderItemIdentifier.item(for: descendant.path).rawValue
                state.snapshots[childID] = nil
                state.records[childID] = nil
            }
            state.snapshots[identifier] = nil
        }
        state.records[identifier] = nil
    }

    private func persist() {
        guard let storeURL, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

func noSuchItemError() -> NSError {
    NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.noSuchItem.rawValue)
}

func unsupportedError() -> NSError {
    NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
}

func fileProviderError(for error: Error) -> NSError {
    let nsError = error as NSError
    if nsError.domain == NSFileProviderErrorDomain {
        return nsError
    }
    return NSError(
        domain: NSFileProviderErrorDomain,
        code: NSFileProviderError.serverUnreachable.rawValue,
        userInfo: [NSUnderlyingErrorKey: error]
    )
}
