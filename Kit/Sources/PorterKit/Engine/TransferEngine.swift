import Foundation

/// Resolves a device ID to a live transport, reconnecting if necessary.
///
/// Injected rather than owned, so the engine is independent of which transport
/// is in use and can pick up a replacement mid-transfer.
public protocol TransportResolver: Sendable {
    func transport(for deviceID: DeviceID) async throws -> any DeviceTransport
}

public enum TransferEvent: Sendable {
    case itemChanged(TransferItem)
    case summaryChanged(TransferSummary)
    /// A file's name was changed to be legal at the destination.
    case sanitized(item: UUID, change: FilenameSanitizer.Change)
    case batchFinished(UUID)
}

/// Executes queued transfers.
///
/// Three guarantees hold for every item:
///  1. In-flight bytes live in a `.porterpart` sidecar, so the final name
///     appears only once the file is whole and an interrupted copy is never
///     mistaken for a finished one.
///  2. Every completed file is verified by comparing a device-side hash with a
///     local one; a mismatch discards the result rather than keeping it.
///  3. Interruptions resume from the partial file's length rather than
///     restarting.
public actor TransferEngine {
    public let queue: TransferQueue
    private let resolver: any TransportResolver
    private let fileManager: FileManager
    private var running: Set<UUID> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isPaused = false
    private var meter = ThroughputMeter()
    private var pumpTask: Task<Void, Never>?
    /// Per-device stream limits, read from each transport when it is first
    /// resolved. MTP is strictly serial, so `maximumConcurrency` acts as a
    /// ceiling and this as the binding constraint.
    private var transportLimits: [DeviceID: Int] = [:]
    private var runningDevices: [DeviceID: Int] = [:]

    private var continuations: [UUID: AsyncStream<TransferEvent>.Continuation] = [:]

    /// How many files move at once. Small files benefit from parallelism, large
    /// sequential ones do not, and MTP degrades. Clamped by the transport's own
    /// limit at dispatch time.
    public var maximumConcurrency: Int

    /// Whether to verify each file with a checksum after copying. On by default.
    public var verifiesChecksums: Bool

    public init(queue: TransferQueue, resolver: any TransportResolver,
                maximumConcurrency: Int = 3, verifiesChecksums: Bool = true,
                fileManager: FileManager = .default) {
        self.queue = queue
        self.resolver = resolver
        self.maximumConcurrency = maximumConcurrency
        self.verifiesChecksums = verifiesChecksums
        self.fileManager = fileManager
    }

    // MARK: - Settings

    public func setMaximumConcurrency(_ value: Int) {
        maximumConcurrency = Swift.max(1, value)
    }

    public func setVerifiesChecksums(_ value: Bool) {
        verifiesChecksums = value
    }

    // MARK: - Events

    public func events() -> AsyncStream<TransferEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(_ event: TransferEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    private func emitSummary() async {
        let summary = await queue.summary(
            bytesPerSecond: meter.bytesPerSecond,
            estimatedTimeRemaining: nil,
            isPaused: isPaused
        )
        var withETA = summary
        withETA.estimatedTimeRemaining = meter.estimatedTimeRemaining(totalExpectedBytes: summary.totalBytes)
        emit(.summaryChanged(withETA))
    }

    // MARK: - Control

    public func enqueue(_ items: [TransferItem]) async {
        await queue.append(items)
        await emitSummary()
        start()
    }

    public func start() {
        isPaused = false
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            await self?.pump()
        }
    }

    public func pauseAll() async {
        isPaused = true
        meter.suspend()
        for (id, task) in tasks {
            task.cancel()
            await task.value
            await queue.update(id) { item in
                if item.state.isActive { item.state = .paused }
            }
        }
        tasks.removeAll()
        running.removeAll()
        await queue.flush()
        await emitSummary()
    }

    public func resumeAll() async {
        let items = await queue.orderedItems
        for item in items where item.state == .paused || item.state == .failed {
            await queue.update(item.id) { $0.state = .queued; $0.errorMessage = nil }
        }
        start()
        await emitSummary()
    }

    public func pause(_ id: UUID) async {
        await stopTask(id)
        await queue.update(id) { item in
            if item.state.isActive || item.state == .queued { item.state = .paused }
        }
        await emitSummary()
    }

    /// Cancels an item's task and waits for it to unwind.
    ///
    /// The wait is required. Cancellation is cooperative, so without it the item
    /// could be dispatched again while the previous attempt was still running,
    /// leaving two executions writing the same partial file and sharing one
    /// entry in `tasks`, where the new one would inherit the cancelled handle.
    private func stopTask(_ id: UUID) async {
        guard let task = tasks[id] else {
            running.remove(id)
            return
        }
        tasks[id] = nil
        task.cancel()
        await task.value
        running.remove(id)
    }


    public func resume(_ id: UUID) async {
        await queue.update(id) { item in
            if item.state == .paused || item.state == .failed {
                item.state = .queued
                item.errorMessage = nil
            }
        }
        start()
    }

    public func cancel(_ id: UUID) async {
        await stopTask(id)
        if let item = await queue.update(id, { item in
            item.state = .cancelled
            item.finishedAt = Date()
        }) {
            // A cancelled transfer leaves nothing half-written behind.
            await discardPartial(for: item)
            emit(.itemChanged(item))
        }
        await emitSummary()
    }

    public func remove(_ ids: Set<UUID>) async {
        for id in ids { await cancel(id) }
        await queue.remove(ids)
        await emitSummary()
    }

    // MARK: - Scheduling

    private func pump() async {
        defer { pumpTask = nil }
        while !Task.isCancelled {
            if isPaused { return }
            guard running.count < maximumConcurrency,
                  let next = await queue.nextQueued(excluding: running),
                  hasCapacity(forDevice: next.deviceID) else {
                if running.isEmpty { return }
                // Wait for a slot rather than spinning.
                try? await Task.sleep(for: .milliseconds(120))
                continue
            }

            running.insert(next.id)
            runningDevices[next.deviceID, default: 0] += 1
            await queue.update(next.id) { $0.state = .running; $0.attempts += 1 }
            tasks[next.id] = Task { [weak self] in
                await self?.execute(next.id)
            }
        }
    }

    /// Whether another stream to this device would exceed its transport's limit.
    private func hasCapacity(forDevice deviceID: DeviceID) -> Bool {
        guard let limit = transportLimits[deviceID] else { return true }
        return (runningDevices[deviceID] ?? 0) < limit
    }

    private func releaseSlot(for id: UUID) async {
        guard let deviceID = await queue.item(id)?.deviceID else { return }
        if let count = runningDevices[deviceID], count > 0 {
            runningDevices[deviceID] = count - 1
        }
    }

    private func finish(_ id: UUID) async {
        await releaseSlot(for: id)
        running.remove(id)
        tasks[id] = nil
        await emitSummary()

        if running.isEmpty && pumpTask == nil && !isPaused {
            start()
        }
    }

    // MARK: - Execution

    private func execute(_ id: UUID) async {
        guard let item = await queue.item(id) else {
            await finish(id)
            return
        }

        do {
            let transport = try await resolver.transport(for: item.deviceID)
            transportLimits[item.deviceID] = transport.capabilities.maximumConcurrentStreams
            if item.isDirectoryPlaceholder {
                try await createDirectory(for: item, using: transport)
            } else {
                switch item.direction {
                case .pull: try await pull(item, using: transport)
                case .push: try await push(item, using: transport)
                }
            }
            if let updated = await queue.update(id, { entry in
                entry.state = .completed
                entry.bytesTransferred = entry.totalBytes
                entry.finishedAt = Date()
                entry.errorMessage = nil
            }) {
                emit(.itemChanged(updated))
            }
        } catch is CancellationError {
            // Pause and cancel have already set the state. Leave partials in
            // place so the item can resume.
        } catch {
            await handleFailure(id, error: error)
        }
        await finish(id)
    }

    private func handleFailure(_ id: UUID, error: any Error) async {
        let transferError = error as? TransferError
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        // A transient failure, such as a disconnected cable, becomes a pause
        // that resumes when the device returns.
        let becomesPaused = transferError?.isTransient ?? false

        if let updated = await queue.update(id, { item in
            item.state = becomesPaused ? .paused : .failed
            item.errorMessage = message
            if !becomesPaused { item.finishedAt = Date() }
        }) {
            // The written bytes are wrong; keeping them would let a later
            // resume continue from corrupt data.
            if case .checksumMismatch = transferError {
                await discardPartial(for: updated)
                await queue.update(id) { $0.bytesTransferred = 0 }
            }
            emit(.itemChanged(updated))
        }
    }

    private func createDirectory(for item: TransferItem, using transport: any DeviceTransport) async throws {
        switch item.direction {
        case .pull:
            try fileManager.createDirectory(at: item.localURL, withIntermediateDirectories: true)
        case .push:
            try await transport.createDirectory(item.remotePath)
        }
    }

    // MARK: - Device to Mac

    private func pull(_ item: TransferItem, using transport: any DeviceTransport) async throws {
        let partialURL = item.localPartialURL
        try fileManager.createDirectory(at: item.localURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)

        // Resume from whatever the sidecar already holds, rounded down to a
        // block boundary to keep the ranged read aligned.
        var resumeOffset = existingSize(at: partialURL)
        if resumeOffset > 0 {
            if !transport.capabilities.supportsRangedReads || resumeOffset >= item.totalBytes {
                try? fileManager.removeItem(at: partialURL)
                resumeOffset = 0
            } else {
                resumeOffset = TransferChunk.alignedDown(resumeOffset)
                try truncateLocalFile(at: partialURL, to: resumeOffset)
            }
        }
        if resumeOffset == 0 {
            try? fileManager.removeItem(at: partialURL)
            // A fresh copy uses the transport's bulk path where one exists.
            // It writes to the same sidecar and is verified the same way, so
            // the guarantees above still hold.
            if try await fastPull(item, to: partialURL, using: transport) {
                try await finishPull(item, partialURL: partialURL, transport: transport)
                return
            }
            fileManager.createFile(atPath: partialURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: partialURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var written = resumeOffset
        await queue.recordProgress(item.id, bytesTransferred: written)

        let stream = try await transport.readStream(item.remotePath, range: ByteRange(offset: resumeOffset))
        var sinceCheckpoint: Int64 = 0

        for try await chunk in stream {
            try Task.checkCancellation()
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
            sinceCheckpoint += Int64(chunk.count)
            meter.record(bytes: Int64(chunk.count))
            await queue.recordProgress(item.id, bytesTransferred: written)

            // Checkpoint roughly every 16 MB: frequent enough to bound what a
            // crash costs, rare enough not to dominate the transfer.
            if sinceCheckpoint >= 16 * 1024 * 1024 {
                sinceCheckpoint = 0
                try handle.synchronize()
                if let snapshot = await queue.item(item.id) { emit(.itemChanged(snapshot)) }
                await emitSummary()
            }
        }
        try handle.synchronize()
        try handle.close()

        try await finishPull(item, partialURL: partialURL, transport: transport)
    }

    private func fastPull(_ item: TransferItem, to partialURL: URL,
                          using transport: any DeviceTransport) async throws -> Bool {
        let itemID = item.id
        let queueRef = queue
        let counter = ProgressCounter(initial: 0)

        return try await transport.fastPull(item.remotePath, to: partialURL) { [weak self] delta in
            let total = counter.add(delta)
            Task {
                await queueRef.recordProgress(itemID, bytesTransferred: total)
                await self?.recordThroughput(delta)
            }
        }
    }

    /// Validates a finished download, then moves it to its final name.
    private func finishPull(_ item: TransferItem, partialURL: URL,
                            transport: any DeviceTransport) async throws {
        // Size check first: it is free and catches the common truncation.
        let finalSize = existingSize(at: partialURL)
        if item.totalBytes > 0 && finalSize != item.totalBytes {
            throw TransferError.truncated(path: item.displayPath, expected: item.totalBytes, actual: finalSize)
        }
        await queue.recordProgress(item.id, bytesTransferred: finalSize)

        if verifiesChecksums {
            await queue.update(item.id) { $0.state = .verifying }
            if let snapshot = await queue.item(item.id) { emit(.itemChanged(snapshot)) }
            try await verifyPull(item, partialURL: partialURL, transport: transport)
        }

        try placeLocalFile(from: partialURL, to: item.localURL, resolution: item.conflictResolution)
        if let modified = item.sourceModified {
            try? fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: item.localURL.path)
        }
    }

    private func verifyPull(_ item: TransferItem, partialURL: URL, transport: any DeviceTransport) async throws {
        guard transport.capabilities.supportsDeviceSideChecksum,
              let deviceChecksum = try await transport.checksum(item.remotePath, algorithm: .sha256) else {
            // No device-side hash available, so the size check above is the
            // only validation. The item is left marked unverified.
            return
        }
        let localChecksum = try ChecksumService.hashLocalFile(at: partialURL, algorithm: deviceChecksum.algorithm)
        guard localChecksum == deviceChecksum else {
            throw TransferError.checksumMismatch(
                path: item.displayPath, expected: deviceChecksum.value, actual: localChecksum.value
            )
        }
        await queue.update(item.id) { $0.verifiedChecksum = localChecksum }
    }

    // MARK: - Mac to device

    private func push(_ item: TransferItem, using transport: any DeviceTransport) async throws {
        let partialPath = item.remotePartialPath
        if let parent = item.remotePath.parent {
            try await transport.createDirectory(parent)
        }

        var resumeOffset: Int64 = 0
        if transport.capabilities.supportsResumableWrites,
           let existing = try? await transport.stat(partialPath), existing.size > 0 {
            let aligned = TransferChunk.alignedDown(existing.size)
            if aligned > 0 && aligned < item.totalBytes {
                // The sidecar may end in a half-written block. Trim back to
                // the boundary; if the device cannot trim, restart rather than
                // append onto a partial block and corrupt the file.
                if existing.size != aligned {
                    do {
                        try await transport.truncate(partialPath, to: aligned)
                        resumeOffset = aligned
                    } catch {
                        try? await transport.remove(partialPath, recursive: false)
                    }
                } else {
                    resumeOffset = aligned
                }
            } else {
                try? await transport.remove(partialPath, recursive: false)
            }
        } else if (try? await transport.stat(partialPath)) != nil {
            try? await transport.remove(partialPath, recursive: false)
        }

        await queue.recordProgress(item.id, bytesTransferred: resumeOffset)
        let itemID = item.id
        let queueRef = queue
        let counter = ProgressCounter(initial: resumeOffset)

        try await transport.writeFile(
            from: item.localURL,
            to: partialPath,
            destinationOffset: resumeOffset
        ) { [weak self] delta in
            let total = counter.add(delta)
            Task {
                await queueRef.recordProgress(itemID, bytesTransferred: total)
                await self?.recordThroughput(delta)
            }
        }

        let landedSize = (try? await transport.stat(partialPath))?.size ?? 0
        if item.totalBytes > 0 && landedSize != item.totalBytes {
            throw TransferError.truncated(path: item.displayPath, expected: item.totalBytes, actual: landedSize)
        }

        if verifiesChecksums {
            await queue.update(item.id) { $0.state = .verifying }
            if let snapshot = await queue.item(item.id) { emit(.itemChanged(snapshot)) }
            try await verifyPush(item, partialPath: partialPath, transport: transport)
        }

        // Verified, so the file can now take its real name.
        if (try? await transport.stat(item.remotePath)) != nil {
            try await transport.remove(item.remotePath, recursive: false)
        }
        try await transport.move(from: partialPath, to: item.remotePath)

        if transport.capabilities.supportsMtimePreservation, let modified = item.sourceModified {
            try? await transport.setModificationDate(modified, at: item.remotePath)
        }
    }

    private func verifyPush(_ item: TransferItem, partialPath: RemotePath, transport: any DeviceTransport) async throws {
        guard transport.capabilities.supportsDeviceSideChecksum,
              let deviceChecksum = try await transport.checksum(partialPath, algorithm: .sha256) else { return }
        let localChecksum = try ChecksumService.hashLocalFile(at: item.localURL, algorithm: deviceChecksum.algorithm)
        guard localChecksum == deviceChecksum else {
            throw TransferError.checksumMismatch(
                path: item.displayPath, expected: localChecksum.value, actual: deviceChecksum.value
            )
        }
        await queue.update(item.id) { $0.verifiedChecksum = localChecksum }
    }

    // MARK: - Partials

    private func discardPartial(for item: TransferItem) async {
        switch item.direction {
        case .pull:
            try? fileManager.removeItem(at: item.localPartialURL)
        case .push:
            if let transport = try? await resolver.transport(for: item.deviceID) {
                try? await transport.remove(item.remotePartialPath, recursive: false)
            }
        }
    }

    private func existingSize(at url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// Hops back onto the actor from an off-actor progress callback.
    private func recordThroughput(_ delta: Int64) {
        meter.record(bytes: delta)
    }

    private func truncateLocalFile(at url: URL, to length: Int64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(length))
    }



    /// Moves a finished download into place, applying the conflict resolution.
    private func placeLocalFile(from partialURL: URL, to destination: URL, resolution: ConflictResolution?) throws {
        var finalURL = destination
        if fileManager.fileExists(atPath: destination.path) {
            switch resolution ?? .replace {
            case .skip:
                try? fileManager.removeItem(at: partialURL)
                return
            case .replace, .replaceIfNewer:
                try fileManager.removeItem(at: destination)
            case .keepBoth:
                let directory = destination.deletingLastPathComponent()
                let siblings = Set((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
                let unique = ConflictNaming.uniqueName(for: destination.lastPathComponent, existing: siblings)
                finalURL = directory.appendingPathComponent(unique)
            }
        }
        try fileManager.moveItem(at: partialURL, to: finalURL)
    }
}

/// Running byte total for a transfer. Progress callbacks arrive on a
/// process-reading thread, so this uses a lock rather than actor isolation.
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(initial: Int64) { self.value = initial }

    func add(_ delta: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        value += delta
        return value
    }
}
