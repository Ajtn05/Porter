import FileProvider
import Foundation

final class PorterFileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let domainIdentifier: String
    private let containerItemIdentifier: NSFileProviderItemIdentifier
    private let client: PorterFileProviderClient
    private let store: PorterFileProviderItemStore

    init(domainIdentifier: String, containerItemIdentifier: NSFileProviderItemIdentifier,
         client: PorterFileProviderClient, store: PorterFileProviderItemStore) {
        self.domainIdentifier = domainIdentifier
        self.containerItemIdentifier = containerItemIdentifier
        self.client = client
        self.store = store
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let sortedByDate = NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage
        let sortedByName = NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
        guard page == sortedByDate || page == sortedByName else {
            observer.finishEnumerating(upTo: nil)
            return
        }

        let domainIdentifier = domainIdentifier
        let containerItemIdentifier = containerItemIdentifier
        let client = client
        let store = store
        let observer = PorterUncheckedSendable(value: observer)
        Task { @MainActor [domainIdentifier, containerItemIdentifier, client, store, observer] in
            do {
                let records = try await Self.records(
                    in: containerItemIdentifier, domain: domainIdentifier,
                    client: client, store: store
                )
                store.replaceItems(records, in: containerItemIdentifier)
                let items = records.map(PorterFileProviderItem.init(record:))
                observer.value.didEnumerate(items)
                observer.value.finishEnumerating(upTo: nil)
            } catch {
                observer.value.finishEnumeratingWithError(fileProviderError(for: error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let domainIdentifier = domainIdentifier
        let containerItemIdentifier = containerItemIdentifier
        let client = client
        let store = store
        let observer = PorterUncheckedSendable(value: observer)
        Task { @MainActor [domainIdentifier, containerItemIdentifier, client, store, observer] in
            do {
                let records = try await Self.records(
                    in: containerItemIdentifier, domain: domainIdentifier,
                    client: client, store: store
                )
                guard let changes = store.changes(records, in: containerItemIdentifier, from: anchor) else {
                    throw NSError(domain: NSFileProviderErrorDomain,
                                  code: NSFileProviderError.syncAnchorExpired.rawValue)
                }
                if !changes.updated.isEmpty {
                    observer.value.didUpdate(changes.updated.map(PorterFileProviderItem.init(record:)))
                }
                if !changes.deleted.isEmpty {
                    observer.value.didDeleteItems(withIdentifiers: changes.deleted)
                }
                observer.value.finishEnumeratingChanges(upTo: changes.anchor, moreComing: false)
            } catch {
                observer.value.finishEnumeratingWithError(fileProviderError(for: error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(store.anchor(for: containerItemIdentifier))
    }

    private static func records(
        in container: NSFileProviderItemIdentifier,
        domain: String,
        client: PorterFileProviderClient,
        store: PorterFileProviderItemStore
    ) async throws -> [PorterFileProviderRecord] {
        let response: PorterFileProviderResponse
        if container == .workingSet {
            return store.allRecords()
        } else if container == .rootContainer {
            response = try await client.send(.volumes(domainIdentifier: domain))
        } else {
            guard let record = store.record(for: container), record.isDirectory else {
                throw noSuchItemError()
            }
            response = try await client.send(.list(domainIdentifier: domain, path: record.path))
        }
        guard case .items(let records) = response else {
            throw PorterFileProviderBridgeError.invalidResponse
        }
        return records
    }
}
