import Foundation

/// The durable transfer queue.
///
/// Persists across quit, crash, and reboot. Both the item list and each item's
/// byte count are stored on disk alongside the `.porterpart` files they
/// describe, so a relaunch can resume where the previous run stopped.
public actor TransferQueue {
    private var items: [TransferItem] = []
    private var order: [UUID] = []
    private let storeURL: URL
    private var saveTask: Task<Void, Never>?
    /// How long to coalesce writes. Without debouncing, a large batch would
    /// rewrite the manifest thousands of times a second.
    private let saveDebounce: Duration

    public init(storeURL: URL? = nil, saveDebounce: Duration = .milliseconds(750)) {
        self.storeURL = storeURL ?? Self.defaultStoreURL()
        self.saveDebounce = saveDebounce
    }

    public static func defaultStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Porter", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("queue.json")
    }

    // MARK: - Loading and saving

    public func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([TransferItem].self, from: data) else { return }

        items = stored.map { item in
            var item = item
            // Nothing is in flight after a relaunch, so requeue rather than
            // trusting a stale active state.
            if item.state.isActive || item.state == .paused {
                item.state = .queued
            }
            return item
        }
        order = items.map(\.id)
    }

    public func save() async {
        let snapshot = orderedItems
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        // Atomic, so a crash mid-write cannot leave an unreadable manifest.
        try? data.write(to: storeURL, options: .atomic)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [saveDebounce] in
            try? await Task.sleep(for: saveDebounce)
            guard !Task.isCancelled else { return }
            await self.save()
        }
    }

    /// Flushes any pending debounced write. Call before the app terminates.
    public func flush() async {
        saveTask?.cancel()
        saveTask = nil
        await save()
    }

    // MARK: - Access

    public var orderedItems: [TransferItem] {
        order.compactMap { id in items.first { $0.id == id } }
    }

    public func item(_ id: UUID) -> TransferItem? {
        items.first { $0.id == id }
    }

    public func append(_ newItems: [TransferItem]) {
        for item in newItems {
            items.append(item)
            order.append(item.id)
        }
        scheduleSave()
    }

    /// Returns the next item ready to run, in FIFO order.
    public func nextQueued(excluding running: Set<UUID>) -> TransferItem? {
        for id in order where !running.contains(id) {
            if let item = items.first(where: { $0.id == id }), item.state == .queued {
                return item
            }
        }
        return nil
    }

    @discardableResult
    public func update(_ id: UUID, _ mutate: (inout TransferItem) -> Void) -> TransferItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        mutate(&items[index])
        scheduleSave()
        return items[index]
    }

    /// Records a byte count during a transfer.
    ///
    /// Separate from `update` so these frequent writes skip the disk entirely;
    /// the engine's periodic checkpoint provides durability.
    public func recordProgress(_ id: UUID, bytesTransferred: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].bytesTransferred = bytesTransferred
    }

    public func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        order.removeAll { ids.contains($0) }
        scheduleSave()
    }

    /// Removes completed and skipped items, leaving failures in place.
    public func clearCompleted() {
        let doomed = Set(items.filter { $0.state == .completed || $0.state == .skipped }.map(\.id))
        remove(doomed)
    }

    public func summary(bytesPerSecond: Double, estimatedTimeRemaining: TimeInterval?, isPaused: Bool) -> TransferSummary {
        let all = items
        return TransferSummary(
            totalItems: all.count,
            completedItems: all.filter { $0.state == .completed || $0.state == .skipped }.count,
            failedItems: all.filter { $0.state == .failed }.count,
            totalBytes: all.reduce(0) { $0 + $1.totalBytes },
            transferredBytes: all.reduce(0) { $0 + ($1.state == .completed ? $1.totalBytes : $1.bytesTransferred) },
            bytesPerSecond: bytesPerSecond,
            estimatedTimeRemaining: estimatedTimeRemaining,
            isRunning: all.contains { $0.state.isActive },
            isPaused: isPaused
        )
    }
}
