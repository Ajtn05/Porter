import Foundation
import Testing
@testable import PorterKit

/// Deterministic, compressible-but-varied bytes, so a truncation or an
/// off-by-one block shows up as a checksum mismatch rather than passing by luck.
func makePayload(_ byteCount: Int, seed: UInt8 = 7) -> Data {
    var data = Data(capacity: byteCount)
    var value = seed
    for index in 0..<byteCount {
        value = value &* 31 &+ UInt8(truncatingIfNeeded: index)
        data.append(value)
    }
    return data
}

func sha256(_ data: Data) -> Checksum {
    var hasher = ChecksumHasher(algorithm: .sha256)
    hasher.update(data)
    return hasher.finalize()
}

/// Waits for the engine to stop making progress, then returns the final items.
@discardableResult
func settle(_ queue: TransferQueue, timeout: Duration = .seconds(20)) async throws -> [TransferItem] {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let items = await queue.orderedItems
        let busy = items.contains { $0.state == .queued || $0.state.isActive }
        if !busy && !items.isEmpty { return items }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Transfers did not settle within \(timeout)")
    return await queue.orderedItems
}

@Suite("Transfer engine")
struct TransferEngineTests {

    private func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("porter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEngine(_ transport: FakeTransport, sandbox: URL,
                            concurrency: Int = 2) -> (TransferEngine, TransferQueue) {
        let queue = TransferQueue(storeURL: sandbox.appendingPathComponent("queue.json"),
                                  saveDebounce: .milliseconds(10))
        let engine = TransferEngine(queue: queue, resolver: FakeResolver(transport: transport),
                                    maximumConcurrency: concurrency)
        return (engine, queue)
    }

    private func pullItem(_ remote: String, to localURL: URL, size: Int64,
                          modified: Date? = nil, resolution: ConflictResolution? = nil) -> TransferItem {
        TransferItem(batchID: UUID(), direction: .pull, deviceID: "fake",
                     remotePath: RemotePath(remote), localURL: localURL,
                     displayPath: localURL.lastPathComponent, totalBytes: size,
                     sourceModified: modified, conflictResolution: resolution)
    }

    @Test("Copies files off the device and verifies every one")
    func pullVerified() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let transport = FakeTransport()
        let payloads = [
            "/sdcard/a.bin": makePayload(3_100_000, seed: 1),
            "/sdcard/b.bin": makePayload(17, seed: 2),
            "/sdcard/c.bin": makePayload(1_048_576, seed: 3)
        ]
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        for (path, data) in payloads {
            await transport.addFile(path, contents: data, modified: modified)
        }

        let (engine, queue) = makeEngine(transport, sandbox: sandbox)
        let items = payloads.map { path, data in
            pullItem(path, to: sandbox.appendingPathComponent(RemotePath(path).name),
                     size: Int64(data.count), modified: modified)
        }
        await engine.enqueue(items)
        let settled = try await settle(queue)

        #expect(settled.allSatisfy { $0.state == .completed })
        for (path, data) in payloads {
            let local = sandbox.appendingPathComponent(RemotePath(path).name)
            #expect(try Data(contentsOf: local) == data)
            // Every completed item carries the hash it was checked against.
            let item = settled.first { $0.remotePath.string == path }
            #expect(item?.verifiedChecksum == sha256(data))
        }
        // Nothing partial is left lying around.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.path)
            .filter { $0.hasSuffix(TransferItem.partialSuffix) }
        #expect(leftovers.isEmpty)
    }

    @Test("Preserves the modification date on a pulled file")
    func pullPreservesMtime() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/dated.bin", contents: makePayload(2048), modified: modified)

        let (engine, queue) = makeEngine(transport, sandbox: sandbox)
        let local = sandbox.appendingPathComponent("dated.bin")
        await engine.enqueue([pullItem("/sdcard/dated.bin", to: local, size: 2048, modified: modified)])
        try await settle(queue)

        let landed = try local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(abs((landed ?? .distantPast).timeIntervalSince(modified)) < 1)
    }

    @Test("A pulled cable leaves a resumable partial, never a finished-looking file")
    func pullInterruptedLeavesPartial() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let payload = makePayload(4_000_000, seed: 11)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/big.bin", contents: payload)
        // Cut the stream at roughly half, the way a knocked cable does.
        await transport.setFailReadAfterBytes(2_000_000)

        let (engine, queue) = makeEngine(transport, sandbox: sandbox, concurrency: 1)
        let local = sandbox.appendingPathComponent("big.bin")
        let item = pullItem("/sdcard/big.bin", to: local, size: Int64(payload.count))
        await engine.enqueue([item])
        let interrupted = try await settle(queue)

        // A disconnect is a pause, not a failure the user has to clear.
        #expect(interrupted.first?.state == .paused)
        // The crucial guarantee: the real name does not exist yet.
        #expect(!FileManager.default.fileExists(atPath: local.path))
        #expect(FileManager.default.fileExists(atPath: item.localPartialURL.path))

        let partialSize = try Data(contentsOf: item.localPartialURL).count
        #expect(partialSize > 0 && partialSize < payload.count)
    }

    @Test("Reconnecting resumes from the partial instead of restarting")
    func pullResumes() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let payload = makePayload(4_000_000, seed: 13)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/big.bin", contents: payload)
        await transport.setFailReadAfterBytes(2_000_000)

        let (engine, queue) = makeEngine(transport, sandbox: sandbox, concurrency: 1)
        let local = sandbox.appendingPathComponent("big.bin")
        await engine.enqueue([pullItem("/sdcard/big.bin", to: local, size: Int64(payload.count))])
        try await settle(queue)

        // Cable back in.
        await transport.setFailReadAfterBytes(nil)
        await engine.resumeAll()
        let finished = try await settle(queue)

        #expect(finished.first?.state == .completed)
        #expect(try Data(contentsOf: local) == payload)
        #expect(!FileManager.default.fileExists(atPath: local.path + TransferItem.partialSuffix))

        // It resumed rather than started over: the second read asked for a
        // non-zero, block-aligned offset.
        let offset = await transport.lastReadOffset
        #expect(offset > 0)
        #expect(offset % TransferChunk.blockSize == 0)
        #expect(await transport.readCallCount == 2)
    }

    @Test("A file that fails verification is discarded, not kept")
    func checksumMismatchDiscards() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let payload = makePayload(600_000, seed: 17)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/bad.bin", contents: payload)
        await transport.setCorruptChecksum(true)

        let (engine, queue) = makeEngine(transport, sandbox: sandbox, concurrency: 1)
        let local = sandbox.appendingPathComponent("bad.bin")
        let item = pullItem("/sdcard/bad.bin", to: local, size: Int64(payload.count))
        await engine.enqueue([item])
        let settled = try await settle(queue)

        #expect(settled.first?.state == .failed)
        #expect(!FileManager.default.fileExists(atPath: local.path))
        // The bad bytes are gone, so a later resume cannot build on them.
        #expect(!FileManager.default.fileExists(atPath: item.localPartialURL.path))
        #expect(settled.first?.bytesTransferred == 0)
    }

    @Test("A device with no sha256sum still completes on the size check")
    func noChecksumToolStillWorks() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let payload = makePayload(300_000, seed: 19)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/plain.bin", contents: payload)
        await transport.setHasChecksumTool(false)

        let (engine, queue) = makeEngine(transport, sandbox: sandbox, concurrency: 1)
        let local = sandbox.appendingPathComponent("plain.bin")
        await engine.enqueue([pullItem("/sdcard/plain.bin", to: local, size: Int64(payload.count))])
        let settled = try await settle(queue)

        #expect(settled.first?.state == .completed)
        #expect(settled.first?.verifiedChecksum == nil)   // honest: nothing was verified
        #expect(try Data(contentsOf: local) == payload)
    }

    @Test("Keep Both writes alongside the existing file, Finder-style")
    func keepBothOnPull() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let existing = sandbox.appendingPathComponent("photo.jpg")
        try Data("original".utf8).write(to: existing)

        let payload = makePayload(1000, seed: 23)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/photo.jpg", contents: payload)

        let (engine, queue) = makeEngine(transport, sandbox: sandbox, concurrency: 1)
        await engine.enqueue([pullItem("/sdcard/photo.jpg", to: existing,
                                       size: Int64(payload.count), resolution: .keepBoth)])
        try await settle(queue)

        #expect(try Data(contentsOf: existing) == Data("original".utf8))
        let copy = sandbox.appendingPathComponent("photo 2.jpg")
        #expect(try Data(contentsOf: copy) == payload)
    }

    @Test("Cancelling removes the half-written file")
    func cancelCleansUp() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let payload = makePayload(2_000_000, seed: 29)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/slow.bin", contents: payload)
        await transport.setFailReadAfterBytes(500_000)

        let (engine, queue) = makeEngine(transport, sandbox: sandbox, concurrency: 1)
        let local = sandbox.appendingPathComponent("slow.bin")
        let item = pullItem("/sdcard/slow.bin", to: local, size: Int64(payload.count))
        await engine.enqueue([item])
        try await settle(queue)
        #expect(FileManager.default.fileExists(atPath: item.localPartialURL.path))

        await engine.cancel(item.id)
        #expect(await queue.item(item.id)?.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: item.localPartialURL.path))
        #expect(!FileManager.default.fileExists(atPath: local.path))
    }

    @Test("Copies a file onto the device through a sidecar, then renames it")
    func pushVerified() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let payload = makePayload(2_500_000, seed: 31)
        let source = sandbox.appendingPathComponent("upload.bin")
        try payload.write(to: source)

        let transport = FakeTransport()
        try await transport.createDirectory(RemotePath("/sdcard/Download"))

        let (engine, queue) = makeEngine(transport, sandbox: sandbox, concurrency: 1)
        let item = TransferItem(batchID: UUID(), direction: .push, deviceID: "fake",
                                remotePath: RemotePath("/sdcard/Download/upload.bin"),
                                localURL: source, displayPath: "upload.bin",
                                totalBytes: Int64(payload.count),
                                sourceModified: Date(timeIntervalSince1970: 1_650_000_000))
        await engine.enqueue([item])
        let settled = try await settle(queue)

        #expect(settled.first?.state == .completed)
        #expect(await transport.contents(of: "/sdcard/Download/upload.bin") == payload)
        // The sidecar is gone; only the real name remains.
        #expect(await transport.exists("/sdcard/Download/upload.bin.porterpart") == false)
        #expect(settled.first?.verifiedChecksum == sha256(payload))
    }

    @Test("A push that failed verification does not take the real filename")
    func pushMismatchLeavesDestinationUntouched() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let payload = makePayload(120_000, seed: 37)
        let source = sandbox.appendingPathComponent("upload.bin")
        try payload.write(to: source)

        let transport = FakeTransport()
        await transport.setCorruptChecksum(true)
        let (engine, queue) = makeEngine(transport, sandbox: sandbox, concurrency: 1)
        await engine.enqueue([TransferItem(
            batchID: UUID(), direction: .push, deviceID: "fake",
            remotePath: RemotePath("/sdcard/Download/upload.bin"),
            localURL: source, displayPath: "upload.bin", totalBytes: Int64(payload.count)
        )])
        let settled = try await settle(queue)

        #expect(settled.first?.state == .failed)
        #expect(await transport.exists("/sdcard/Download/upload.bin") == false)
    }

    @Test("A fresh copy uses the transport's bulk path, and is still verified")
    func fastPathIsUsedAndVerified() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let payload = makePayload(2_400_000, seed: 47)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/bulk.bin", contents: payload)
        await transport.setSupportsFastPull(true)

        let (engine, queue) = makeEngine(transport, sandbox: sandbox, concurrency: 1)
        let local = sandbox.appendingPathComponent("bulk.bin")
        await engine.enqueue([pullItem("/sdcard/bulk.bin", to: local, size: Int64(payload.count))])
        let settled = try await settle(queue)

        #expect(settled.first?.state == .completed)
        #expect(await transport.fastPullCallCount == 1)
        // The bulk path must not skip streaming's guarantees.
        #expect(await transport.readCallCount == 0)
        #expect(settled.first?.verifiedChecksum == sha256(payload))
        #expect(try Data(contentsOf: local) == payload)
        #expect(!FileManager.default.fileExists(atPath: local.path + TransferItem.partialSuffix))
    }

    @Test("Pausing actually stops the bulk copy instead of letting it finish")
    func pauseStopsTheBulkPath() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // Found on hardware: Pause returned immediately but `adb pull` ran to
        // completion, so a paused 4 GB transfer kept going for another minute.
        let payload = makePayload(3_000_000, seed: 53)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/slow.bin", contents: payload)
        await transport.setSupportsFastPull(true)
        await transport.setFastPullDelay(.milliseconds(4))

        let (engine, queue) = makeEngine(transport, sandbox: sandbox, concurrency: 1)
        let local = sandbox.appendingPathComponent("slow.bin")
        let item = pullItem("/sdcard/slow.bin", to: local, size: Int64(payload.count))
        await engine.enqueue([item])

        // Let it get going, then pause.
        try await Task.sleep(for: .milliseconds(120))
        await engine.pause(item.id)

        let partialSize = (try? Data(contentsOf: item.localPartialURL).count) ?? 0
        #expect(partialSize > 0)
        #expect(partialSize < payload.count)   // it really stopped
        #expect(!FileManager.default.fileExists(atPath: local.path))

        // And pause left nothing running, so nothing grows behind our back.
        let afterPause = partialSize
        try await Task.sleep(for: .milliseconds(200))
        #expect(((try? Data(contentsOf: item.localPartialURL).count) ?? 0) == afterPause)
    }

    @Test("A paused then resumed file still ends up verified")
    func resumeStillVerifies() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // Found on hardware: the interrupted attempt poisoned the transport's
        // cached answer to "can this device hash files?", so the resumed copy
        // completed while quietly reporting that nothing had been verified.
        let payload = makePayload(3_000_000, seed: 59)
        let transport = FakeTransport()
        await transport.addFile("/sdcard/resume.bin", contents: payload)
        await transport.setSupportsFastPull(true)
        await transport.setFastPullDelay(.milliseconds(4))

        let (engine, queue) = makeEngine(transport, sandbox: sandbox, concurrency: 1)
        let local = sandbox.appendingPathComponent("resume.bin")
        let item = pullItem("/sdcard/resume.bin", to: local, size: Int64(payload.count))
        await engine.enqueue([item])

        try await Task.sleep(for: .milliseconds(120))
        await engine.pause(item.id)
        #expect(await queue.item(item.id)?.state == .paused)

        await transport.setFastPullDelay(.zero)
        await engine.resume(item.id)
        let settled = try await settle(queue)

        #expect(settled.first?.state == .completed)
        #expect(settled.first?.verifiedChecksum == sha256(payload))
        #expect(try Data(contentsOf: local) == payload)
    }

    @Test("A serial transport is never given two streams at once")
    func serialTransportIsNotParallelised() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // MTP is strictly serial: two concurrent streams are slower than one,
        // and some devices simply fail. The user's concurrency preference is a
        // ceiling, and the transport's own limit wins.
        let transport = FakeTransport(kind: .mtp, capabilities: TransportCapabilities(
            supportsRangedReads: false, supportsResumableWrites: false,
            supportsDeviceSideChecksum: true, supportsMtimePreservation: false,
            reportsAccurateSizes: false, maximumConcurrentStreams: 1
        ))
        for index in 0..<6 {
            await transport.addFile("/sdcard/f\(index).bin", contents: makePayload(120_000, seed: UInt8(index + 1)))
        }

        // Engine allowed 4; the transport says 1.
        let (engine, queue) = makeEngine(transport, sandbox: sandbox, concurrency: 4)
        let items = (0..<6).map { index in
            pullItem("/sdcard/f\(index).bin",
                     to: sandbox.appendingPathComponent("f\(index).bin"),
                     size: 120_000)
        }
        await engine.enqueue(items)

        var peakConcurrent = 0
        for _ in 0..<80 {
            let active = await queue.orderedItems.filter { $0.state.isActive }.count
            peakConcurrent = max(peakConcurrent, active)
            if await queue.orderedItems.allSatisfy({ $0.state.isTerminal }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let settled = try await settle(queue)

        #expect(settled.allSatisfy { $0.state == .completed })
        #expect(peakConcurrent <= 1)
    }

    @Test("Reports a real rate and a real ETA, or nothing at all")
    func throughputAndETA() {
        var meter = ThroughputMeter()
        // Two samples one second apart, 10 MB each.
        meter.record(bytes: 10_000_000, at: 0)
        meter.record(bytes: 10_000_000, at: 1)
        meter.record(bytes: 10_000_000, at: 2)
        #expect(meter.totalBytes == 30_000_000)
        #expect(abs(meter.bytesPerSecond - 10_000_000) < 1_000_000)

        let remaining = meter.estimatedTimeRemaining(totalExpectedBytes: 130_000_000)
        #expect(remaining != nil)
        #expect(abs((remaining ?? 0) - 10) < 2)

        // With no samples there is no honest estimate to give.
        let fresh = ThroughputMeter()
        #expect(fresh.estimatedTimeRemaining(totalExpectedBytes: 1000) == nil)
        #expect(fresh.bytesPerSecond == 0)
    }
}
