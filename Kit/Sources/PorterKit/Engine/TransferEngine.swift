import Foundation

/// Resolves a device ID to a live transport, reconnecting if necessary.
///
/// Injected rather than owned so the engine does not care whether the bytes are
/// about to travel over a cable or the LAN — and so a transfer can change its
/// mind mid-flight when the cable is pulled.
public protocol TransportResolver: Sendable {
    func transport(for deviceID: DeviceID) async throws -> any DeviceTransport
}

public enum TransferEvent: Sendable {
    case itemChanged(TransferItem)
    case summaryChanged(TransferSummary)
    /// A file's name had to change to be legal at the destination.
    case sanitized(item: UUID, change: FilenameSanitizer.Change)
    case batchFinished(UUID)
}

/// Moves bytes, and refuses to lie about it.
///
/// Three guarantees hold for every item:
///  1. In-flight bytes live in a `.porterpart` sidecar. The final name only ever
///     appears once the file is whole, so an interrupted copy can never be
///     mistaken for a finished one.
///  2. Every completed file is verified. The device hashes its own copy, we hash
///     ours, and a mismatch discards the result instead of keeping it.
///  3. Interruptions resume. The partial file's length is the resume point, so
///     reconnecting continues rather than restarting.
public actor TransferEngine {
    public let queue: TransferQueue
    private let resolver: any TransportResolver
    private let fileManager: FileManager
    private var running: Set<UUID> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isPaused = false
    private var meter = ThroughputMeter()
    private var pumpTask: Task<Void, Never>?
    /// How many streams each device will tolerate, learned when its transport is
    /// first resolved. MTP is strictly serial, and running two streams over it
    /// is slower than running one - so the user's concurrency preference is a
    /// ceiling, never a floor.
    private var transportLimits: [DeviceID: Int] = [:]
    private var runningDevices: [DeviceID: Int] = [:]

    private var continuations: [UUID: AsyncStream<TransferEvent>.Continuation] = [:]

    /// How many files move at once. Small files benefit from parallelism; large
    /// sequential ones do not, and MTP actively degrades. Clamped by the
    /// transport's own limit at dispatch time.
    public var maximumConcurrency: Int

    /// Verify with checksums after copying. On by default; the acceptance bar is
    /// 20 GB with zero corrupted files, and you cannot claim that without checking.
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

    /// Cancels an item's task and waits for it to actually unwind.
    ///
    /// Waiting matters. Cancellation is cooperative, so the task keeps running
    /// until it reaches its next check - and without this the item could be
    /// dispatched again while the previous attempt was still alive, leaving two
    /// executions writing the same partial file and sharing one entry in
    /// `tasks`, so the new one inherited the old one's cancelled handle.
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

    /// Whether another stream to this device would exceed what its transport
    /// says it can handle.
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
            // Pause and cancel already set the right state; leave partials in
            // place so the item can resume.
        } catch {
            await handleFailure(id, error: error)
        }
        await finish(id)
    }

    private func handleFailure(_ id: UUID, error: any Error) async {
        let transferError = error as? TransferError
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        // A yanked cable is not a failure the user has to act on; it is a pause
        // that resumes when the device comes back.
        let becomesPaused = transferError?.isTransient ?? false

        if let updated = await queue.update(id, { item in
            item.state = becomesPaused ? .paused : .failed
            item.errorMessage = message
            if !becomesPaused { item.finishedAt = Date() }
        }) {
            // A checksum mismatch means the bytes on disk are wrong. Keeping
            // them would let a later resume "continue" from corrupt data.
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

        // Resume point: whatever is already in the sidecar, rounded down to a
        // block boundary so the ranged read stays aligned.
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
            // A fresh copy takes the transport's bulk path when it has one; it
            // is markedly faster, and the sidecar plus checksum guarantees are
            // unaffected because it writes to the same place and is verified
            // the same way.
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

            // Checkpoint roughly every 16 MB: often enough that a crash costs
            // little, rare enough that it is not the bottleneck.
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

    /// Everything a finished download still has to pass before it earns its name.
    private func finishPull(_ item: TransferItem, partialURL: URL,
                            transport: any DeviceTransport) async throws {
        // Size check first: it is free, and it catches the common truncation.
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
            // No hash available on this device. The size check above is the only
            // guarantee we can honestly offer, and we do not pretend otherwise.
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
                // The tail of the sidecar may be a half-written block. Trim back
                // to the boundary; if the device cannot trim, start over rather
                // than append onto a partial block and corrupt the file.
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

        // Only now does the file take its real name.
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

    /// Progress callbacks arrive off-actor; this is the hop back on.
    private func recordThroughput(_ delta: Int64) {
        meter.record(bytes: delta)
    }

    private func truncateLocalFile(at url: URL, to length: Int64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(length))
    }



    /// Moves a finished download into place, honouring the conflict choice.
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

/// Progress callbacks arrive from a process-reading thread, so the running total
/// needs a lock rather than actor isolation.
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
