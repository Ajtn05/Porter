import Foundation
import Testing
@testable import PorterKit

/// A transport that can only hash one file at a time, so the protocol's own
/// fallback is the thing under test rather than an override of it. Everything
/// unrelated to hashing throws: reaching it would mean the test drifted.
private actor OneAtATimeTransport: DeviceTransport {
    nonisolated let kind: TransportKind = .mtp
    nonisolated var capabilities: TransportCapabilities {
        TransportCapabilities(
            supportsRangedReads: false, supportsResumableWrites: false,
            supportsDeviceSideChecksum: true, supportsMtimePreservation: false,
            reportsAccurateSizes: false, maximumConcurrentStreams: 1
        )
    }

    private var files: [String: Data]
    private(set) var callCount = 0

    init(files: [String: Data]) { self.files = files }

    func currentDevice() async throws -> Device { Device(id: "one", displayName: "One", transport: kind) }
    func connect() async throws {}
    func disconnect() async {}

    func checksum(_ path: RemotePath, algorithm: ChecksumAlgorithm) async throws -> Checksum? {
        callCount += 1
        guard let data = files[path.string] else { return nil }
        var hasher = ChecksumHasher(algorithm: algorithm)
        hasher.update(data)
        return hasher.finalize()
    }

    private var unsupported: TransferError { .unsupported(operation: "test stub", transport: .mtp) }

    func volumes() async throws -> [StorageVolume] { throw unsupported }
    func list(_ path: RemotePath) async throws -> [RemoteFile] { throw unsupported }
    func stat(_ path: RemotePath) async throws -> RemoteFile? { throw unsupported }
    func createDirectory(_ path: RemotePath) async throws { throw unsupported }
    func remove(_ path: RemotePath, recursive: Bool) async throws { throw unsupported }
    func move(from source: RemotePath, to destination: RemotePath) async throws { throw unsupported }
    func freeSpace(for volume: StorageVolume) async throws -> FreeSpaceReport { throw unsupported }
    func readStream(_ path: RemotePath, range: ByteRange) async throws -> AsyncThrowingStream<Data, any Error> {
        throw unsupported
    }
    func writeFile(from localURL: URL, to path: RemotePath, destinationOffset: Int64,
                   progress: @escaping @Sendable (Int64) -> Void) async throws { throw unsupported }
    func setModificationDate(_ date: Date, at path: RemotePath) async throws { throw unsupported }
}

@Suite("Batched checksums")
struct BatchedChecksumTests {

    // MARK: - Parsing

    @Test("Reads a hash per line and keys it by the path that was asked for")
    func parsesManyLines() {
        let output = """
        \(String(repeating: "a", count: 64))  /sdcard/one.jpg
        \(String(repeating: "b", count: 64))  /sdcard/two.jpg
        """
        let parsed = ChecksumService.parseSumLines(output, algorithm: .sha256)

        #expect(parsed.count == 2)
        #expect(parsed["/sdcard/one.jpg"]?.value == String(repeating: "a", count: 64))
        #expect(parsed["/sdcard/two.jpg"]?.value == String(repeating: "b", count: 64))
    }

    @Test("A name with spaces in it survives, because only the first two are the separator")
    func parsesSpacedNames() {
        let hex = String(repeating: "c", count: 64)
        let parsed = ChecksumService.parseSumLines("\(hex)  /sdcard/My Photos/a b.jpg", algorithm: .sha256)

        #expect(parsed["/sdcard/My Photos/a b.jpg"]?.value == hex)
    }

    @Test("The binary marker is a separator, not part of the name")
    func parsesBinaryMarker() {
        let hex = String(repeating: "d", count: 64)
        let parsed = ChecksumService.parseSumLines("\(hex) */sdcard/a.bin", algorithm: .sha256)

        #expect(parsed["/sdcard/a.bin"]?.value == hex)
    }

    @Test("An escaped name is dropped rather than keyed under a path nobody asked for")
    func skipsEscapedNames() {
        let good = String(repeating: "e", count: 64)
        let output = """
        \\\(String(repeating: "f", count: 64))  /sdcard/od\\nd.jpg
        \(good)  /sdcard/plain.jpg
        """
        let parsed = ChecksumService.parseSumLines(output, algorithm: .sha256)

        #expect(parsed.count == 1)
        #expect(parsed["/sdcard/plain.jpg"]?.value == good)
    }

    @Test("Lines that are not a hash are ignored, so one stderr leak costs nothing")
    func skipsJunkLines() {
        let hex = String(repeating: "1", count: 64)
        let output = """
        sha256sum: /sdcard/gone.jpg: No such file or directory
        \(hex)  /sdcard/here.jpg
        """
        let parsed = ChecksumService.parseSumLines(output, algorithm: .sha256)

        #expect(parsed.count == 1)
        #expect(parsed["/sdcard/here.jpg"]?.value == hex)
    }

    @Test("md5 lines are half the width and are not read as truncated sha256")
    func parsesMD5Width() {
        let md5 = String(repeating: "9", count: 32)
        let parsed = ChecksumService.parseSumLines("\(md5)  /sdcard/a.jpg", algorithm: .md5)

        #expect(parsed["/sdcard/a.jpg"]?.value == md5)
        #expect(ChecksumService.parseSumLines("\(md5)  /sdcard/a.jpg", algorithm: .sha256).isEmpty)
    }

    // MARK: - Command line splitting

    @Test("A batch is split once it holds more paths than the device will take")
    func splitsOnCount() {
        let paths = (0..<150).map { RemotePath("/sdcard/f\($0).jpg") }
        let batches = ADBTransport.checksumBatches(paths)

        #expect(batches.count == 3)
        #expect(batches.allSatisfy { $0.count <= 64 })
        #expect(batches.flatMap { $0 } == paths)
    }

    @Test("A batch is split on command length too, so long paths do not overrun the shell")
    func splitsOnLength() {
        let long = String(repeating: "d", count: 900)
        let paths = (0..<40).map { RemotePath("/sdcard/\(long)/f\($0).jpg") }
        let batches = ADBTransport.checksumBatches(paths)

        #expect(batches.count > 1)
        #expect(batches.flatMap { $0 } == paths)
        for batch in batches {
            let length = batch.map(\.shellQuoted.utf8.count).reduce(0, +) + batch.count
            #expect(length <= 8 * 1024)
        }
    }

    @Test("Splitting nothing asks for nothing")
    func splitsEmpty() {
        #expect(ADBTransport.checksumBatches([]).isEmpty)
    }

    // MARK: - The fallback

    @Test("A transport with no batch support still answers, one call per path")
    func defaultLoops() async throws {
        let payload = makePayload(64)
        let transport = OneAtATimeTransport(files: ["/sdcard/a.jpg": payload, "/sdcard/b.jpg": payload])

        let result = try await transport.checksums(
            [RemotePath("/sdcard/a.jpg"), RemotePath("/sdcard/b.jpg"), RemotePath("/sdcard/gone.jpg")],
            algorithm: .sha256
        )

        #expect(result.count == 2)
        #expect(result[RemotePath("/sdcard/a.jpg")] == sha256(payload))
        // The path the device had no hash for is absent, not present and wrong.
        #expect(result[RemotePath("/sdcard/gone.jpg")] == nil)
        #expect(await transport.callCount == 3)
    }
}

@Suite("Batched verification in the engine")
struct EngineBatchingTests {

    private func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("porter-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEngine(_ transport: FakeTransport, sandbox: URL,
                            concurrency: Int = 1) -> (TransferEngine, TransferQueue) {
        let queue = TransferQueue(storeURL: sandbox.appendingPathComponent("queue.json"),
                                  saveDebounce: .milliseconds(10))
        let engine = TransferEngine(queue: queue, resolver: FakeResolver(transport: transport),
                                    maximumConcurrency: concurrency)
        return (engine, queue)
    }

    private func pullItem(_ remote: String, to localURL: URL, size: Int64) -> TransferItem {
        TransferItem(batchID: UUID(), direction: .pull, deviceID: "fake",
                     remotePath: RemotePath(remote), localURL: localURL,
                     displayPath: localURL.lastPathComponent, totalBytes: size)
    }

    @Test("A folder of small files is hashed in batches, not once per file")
    func batchesSmallFiles() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let transport = FakeTransport()
        var payloads: [String: Data] = [:]
        for index in 0..<40 {
            let path = "/sdcard/DCIM/thumb\(index).jpg"
            let data = makePayload(2048, seed: UInt8(index % 251))
            payloads[path] = data
            await transport.addFile(path, contents: data)
        }

        let (engine, queue) = makeEngine(transport, sandbox: sandbox)
        await engine.enqueue(payloads.map { path, data in
            pullItem(path, to: sandbox.appendingPathComponent(RemotePath(path).name),
                     size: Int64(data.count))
        })
        let settled = try await settle(queue)

        #expect(settled.count == 40)
        #expect(settled.allSatisfy { $0.state == .completed })
        // Every file still carries a hash it was checked against.
        #expect(settled.allSatisfy { $0.verifiedChecksum != nil })

        let batches = await transport.checksumBatchSizes
        let singles = await transport.checksumCallCount
        // The first file to verify pays for a call covering the ones behind it,
        // so the run costs a handful of round trips rather than one per file.
        #expect(batches.count < 10)
        #expect(batches.first ?? 0 > 1)
        #expect(singles == 0)
    }

    @Test("A large file is hashed on its own rather than holding up a batch")
    func doesNotBatchLargeFiles() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let transport = FakeTransport()
        let payload = makePayload(9 * 1024 * 1024)
        await transport.addFile("/sdcard/movie.bin", contents: payload)

        let (engine, queue) = makeEngine(transport, sandbox: sandbox)
        await engine.enqueue([
            pullItem("/sdcard/movie.bin", to: sandbox.appendingPathComponent("movie.bin"),
                     size: Int64(payload.count))
        ])
        let settled = try await settle(queue)

        #expect(settled.allSatisfy { $0.state == .completed })
        #expect(await transport.checksumCallCount == 1)
        #expect(await transport.checksumBatchSizes.isEmpty)
    }

    @Test("Batching does not weaken verification: a corrupt file is still discarded")
    func batchedVerificationStillCatchesCorruption() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let transport = FakeTransport()
        var names: [String] = []
        for index in 0..<8 {
            let path = "/sdcard/DCIM/small\(index).jpg"
            names.append(RemotePath(path).name)
            await transport.addFile(path, contents: makePayload(1024, seed: UInt8(index)))
        }
        await transport.setCorruptChecksum(true)

        let (engine, queue) = makeEngine(transport, sandbox: sandbox)
        await engine.enqueue(names.map { name in
            pullItem("/sdcard/DCIM/\(name)", to: sandbox.appendingPathComponent(name), size: 1024)
        })
        let settled = try await settle(queue)

        #expect(settled.allSatisfy { $0.state == .failed })
        // A file that failed verification never takes its real name, batched or
        // not, and its partial is discarded rather than left to be resumed.
        for name in names {
            #expect(!FileManager.default.fileExists(atPath: sandbox.appendingPathComponent(name).path))
        }
    }

    @Test("A device with no hashing tool completes the batch unverified rather than failing it")
    func batchWithoutChecksumTool() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let transport = FakeTransport()
        for index in 0..<6 {
            await transport.addFile("/sdcard/f\(index).bin", contents: makePayload(512, seed: UInt8(index)))
        }
        await transport.setHasChecksumTool(false)

        let (engine, queue) = makeEngine(transport, sandbox: sandbox)
        await engine.enqueue((0..<6).map { index in
            pullItem("/sdcard/f\(index).bin",
                     to: sandbox.appendingPathComponent("f\(index).bin"), size: 512)
        })
        let settled = try await settle(queue)

        #expect(settled.allSatisfy { $0.state == .completed })
        #expect(settled.allSatisfy { $0.verifiedChecksum == nil })
    }

    @Test("Regression: a hash fetched for one file is never spent on another")
    func cachedHashesStayWithTheirFile() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // Same length, different bytes: a hash handed to the wrong file passes
        // the size check and can only be caught by the comparison itself.
        let transport = FakeTransport()
        var payloads: [String: Data] = [:]
        for index in 0..<12 {
            let path = "/sdcard/same\(index).bin"
            let data = makePayload(4096, seed: UInt8(index + 1))
            payloads[path] = data
            await transport.addFile(path, contents: data)
        }

        let (engine, queue) = makeEngine(transport, sandbox: sandbox, concurrency: 3)
        await engine.enqueue(payloads.map { path, data in
            pullItem(path, to: sandbox.appendingPathComponent(RemotePath(path).name),
                     size: Int64(data.count))
        })
        let settled = try await settle(queue)

        #expect(settled.allSatisfy { $0.state == .completed })
        for (path, data) in payloads {
            let local = sandbox.appendingPathComponent(RemotePath(path).name)
            #expect(try Data(contentsOf: local) == data)
            let item = settled.first { $0.remotePath == RemotePath(path) }
            #expect(item?.verifiedChecksum == sha256(data))
        }
    }
}

@Suite("Batched reads")
struct BulkPullTests {

    private func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("porter-bulk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEngine(_ transport: FakeTransport, sandbox: URL,
                            concurrency: Int = 1) -> (TransferEngine, TransferQueue) {
        let queue = TransferQueue(storeURL: sandbox.appendingPathComponent("queue.json"),
                                  saveDebounce: .milliseconds(10))
        let engine = TransferEngine(queue: queue, resolver: FakeResolver(transport: transport),
                                    maximumConcurrency: concurrency)
        return (engine, queue)
    }

    private func pullItem(_ remote: String, to localURL: URL, size: Int64) -> TransferItem {
        TransferItem(batchID: UUID(), direction: .pull, deviceID: "fake",
                     remotePath: RemotePath(remote), localURL: localURL,
                     displayPath: localURL.lastPathComponent, totalBytes: size)
    }

    // MARK: - Command line splitting

    @Test("A batch is split once it holds more files than one pull will take")
    func splitsOnCount() {
        let requests = (0..<150).map {
            BulkPullRequest(path: RemotePath("/sdcard/f\($0).jpg"),
                            localURL: URL(fileURLWithPath: "/tmp/f\($0).jpg.porterpart"))
        }
        let batches = ADBTransport.pullBatches(requests)

        #expect(batches.count == 3)
        #expect(batches.allSatisfy { $0.count <= 64 })
        #expect(batches.flatMap { $0 } == requests)
    }

    @Test("Two files of the same name never share a batch, which would overwrite one")
    func splitsOnNameCollision() {
        let requests = [
            BulkPullRequest(path: RemotePath("/sdcard/DCIM/a.jpg"),
                            localURL: URL(fileURLWithPath: "/tmp/one/a.jpg.porterpart")),
            BulkPullRequest(path: RemotePath("/sdcard/Download/a.jpg"),
                            localURL: URL(fileURLWithPath: "/tmp/one/a2.jpg.porterpart"))
        ]
        let batches = ADBTransport.pullBatches(requests)

        #expect(batches.count == 2)
        #expect(batches.flatMap { $0 } == requests)
    }

    @Test("A long list of long paths is split to fit the command line")
    func splitsOnLength() {
        let long = String(repeating: "d", count: 900)
        let requests = (0..<40).map {
            BulkPullRequest(path: RemotePath("/sdcard/\(long)/f\($0).jpg"),
                            localURL: URL(fileURLWithPath: "/tmp/f\($0).jpg.porterpart"))
        }
        let batches = ADBTransport.pullBatches(requests)

        #expect(batches.count > 1)
        #expect(batches.flatMap { $0 } == requests)
        for batch in batches {
            let length = batch.map(\.path.string.utf8.count).reduce(0, +) + batch.count
            #expect(length <= 8 * 1024)
        }
    }

    // MARK: - The engine

    @Test("A folder of small files is read in one call, not one call each")
    func batchesSmallReads() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let transport = FakeTransport()
        await transport.setSupportsBulkPull(true)
        var payloads: [String: Data] = [:]
        for index in 0..<40 {
            let path = "/sdcard/DCIM/thumb\(index).jpg"
            let data = makePayload(2048, seed: UInt8(index % 251))
            payloads[path] = data
            await transport.addFile(path, contents: data)
        }

        let (engine, queue) = makeEngine(transport, sandbox: sandbox)
        await engine.enqueue(payloads.map { path, data in
            pullItem(path, to: sandbox.appendingPathComponent(RemotePath(path).name),
                     size: Int64(data.count))
        })
        let settled = try await settle(queue)

        #expect(settled.count == 40)
        #expect(settled.allSatisfy { $0.state == .completed })
        #expect(settled.allSatisfy { $0.verifiedChecksum != nil })
        for (path, data) in payloads {
            let local = sandbox.appendingPathComponent(RemotePath(path).name)
            #expect(try Data(contentsOf: local) == data)
        }

        // One batch covered the folder, and no file fell back to a stream of
        // its own.
        #expect(await transport.bulkPullSizes.count < 5)
        #expect(await transport.readCallCount == 0)
    }

    @Test("A large file is read on its own rather than held up in a batch")
    func doesNotBatchLargeReads() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let transport = FakeTransport()
        await transport.setSupportsBulkPull(true)
        let payload = makePayload(9 * 1024 * 1024)
        await transport.addFile("/sdcard/movie.bin", contents: payload)

        let (engine, queue) = makeEngine(transport, sandbox: sandbox)
        await engine.enqueue([
            pullItem("/sdcard/movie.bin", to: sandbox.appendingPathComponent("movie.bin"),
                     size: Int64(payload.count))
        ])
        let settled = try await settle(queue)

        #expect(settled.allSatisfy { $0.state == .completed })
        #expect(await transport.bulkPullSizes.isEmpty)
        #expect(await transport.readCallCount == 1)
    }

    @Test("A file the batch would not deliver is still copied on its own")
    func fallsBackForUndelivered() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let transport = FakeTransport()
        await transport.setSupportsBulkPull(true)
        await transport.setBulkPullOmits(["/sdcard/skipped.bin"])

        var payloads: [String: Data] = [:]
        for name in ["a.bin", "skipped.bin", "c.bin"] {
            let path = "/sdcard/\(name)"
            let data = makePayload(1024, seed: UInt8(name.count))
            payloads[path] = data
            await transport.addFile(path, contents: data)
        }

        let (engine, queue) = makeEngine(transport, sandbox: sandbox)
        await engine.enqueue(payloads.map { path, data in
            pullItem(path, to: sandbox.appendingPathComponent(RemotePath(path).name),
                     size: Int64(data.count))
        })
        let settled = try await settle(queue)

        #expect(settled.allSatisfy { $0.state == .completed })
        for (path, data) in payloads {
            let local = sandbox.appendingPathComponent(RemotePath(path).name)
            #expect(try Data(contentsOf: local) == data)
        }
        // The one the batch left out came down the single-file path.
        #expect(await transport.readCallCount >= 1)
    }

    @Test("A transport with no batch read copies every file the old way")
    func withoutBulkSupport() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let transport = FakeTransport()
        var payloads: [String: Data] = [:]
        for index in 0..<5 {
            let path = "/sdcard/f\(index).bin"
            let data = makePayload(1024, seed: UInt8(index))
            payloads[path] = data
            await transport.addFile(path, contents: data)
        }

        let (engine, queue) = makeEngine(transport, sandbox: sandbox)
        await engine.enqueue(payloads.map { path, data in
            pullItem(path, to: sandbox.appendingPathComponent(RemotePath(path).name),
                     size: Int64(data.count))
        })
        let settled = try await settle(queue)

        #expect(settled.allSatisfy { $0.state == .completed })
        #expect(await transport.bulkPullSizes.isEmpty)
        #expect(await transport.readCallCount == 5)
        for (path, data) in payloads {
            #expect(try Data(contentsOf: sandbox.appendingPathComponent(RemotePath(path).name)) == data)
        }
    }

    @Test("Regression: concurrent dispatch never lets two copies write one sidecar")
    func concurrentDispatchStaysCorrect() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // Same length, different bytes: a file written twice, or written with
        // another file's bytes, passes the size check and shows up only in the
        // comparison.
        let transport = FakeTransport()
        await transport.setSupportsBulkPull(true)
        var payloads: [String: Data] = [:]
        for index in 0..<24 {
            let path = "/sdcard/same\(index).bin"
            let data = makePayload(4096, seed: UInt8(index + 1))
            payloads[path] = data
            await transport.addFile(path, contents: data)
        }

        let (engine, queue) = makeEngine(transport, sandbox: sandbox, concurrency: 4)
        await engine.enqueue(payloads.map { path, data in
            pullItem(path, to: sandbox.appendingPathComponent(RemotePath(path).name),
                     size: Int64(data.count))
        })
        let settled = try await settle(queue)

        #expect(settled.allSatisfy { $0.state == .completed })
        for (path, data) in payloads {
            let local = sandbox.appendingPathComponent(RemotePath(path).name)
            #expect(try Data(contentsOf: local) == data)
            #expect(settled.first { $0.remotePath == RemotePath(path) }?.verifiedChecksum == sha256(data))
        }
        // No sidecar is left behind by a batch that raced with a dispatch.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.path)
            .filter { $0.hasSuffix(".porterpart") }
        #expect(leftovers.isEmpty)
    }

    @Test("A batched read is still verified, so corruption is still discarded")
    func batchedReadsAreVerified() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let transport = FakeTransport()
        await transport.setSupportsBulkPull(true)
        for index in 0..<8 {
            await transport.addFile("/sdcard/f\(index).bin", contents: makePayload(1024, seed: UInt8(index)))
        }
        await transport.setCorruptChecksum(true)

        let (engine, queue) = makeEngine(transport, sandbox: sandbox)
        await engine.enqueue((0..<8).map { index in
            pullItem("/sdcard/f\(index).bin",
                     to: sandbox.appendingPathComponent("f\(index).bin"), size: 1024)
        })
        let settled = try await settle(queue)

        #expect(settled.allSatisfy { $0.state == .failed })
        for index in 0..<8 {
            let local = sandbox.appendingPathComponent("f\(index).bin")
            #expect(!FileManager.default.fileExists(atPath: local.path))
        }
    }
}
