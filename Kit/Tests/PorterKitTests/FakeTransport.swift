import Foundation
@testable import PorterKit

/// An in-memory Android device.
///
/// Lets the engine's guarantees - resume, verification, and never leaving a
/// partial file under its final name - be tested deterministically, including
/// failures that cannot be staged reliably on real hardware: a cable pulled at
/// exactly 50%, a device that corrupts a byte, a ROM with no `sha256sum`.
actor FakeTransport: DeviceTransport {
    nonisolated let kind: TransportKind
    private var configuredCapabilities: TransportCapabilities

    nonisolated let capabilitiesBox: CapabilitiesBox

    nonisolated var capabilities: TransportCapabilities { capabilitiesBox.value }

    final class CapabilitiesBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: TransportCapabilities
        init(_ value: TransportCapabilities) { stored = value }
        var value: TransportCapabilities {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    var files: [String: Data] = [:]
    var directories: Set<String> = ["/"]
    var modificationDates: [String: Date] = [:]

    /// When set, a read throws after this many bytes, simulating a cable pull.
    var failReadAfterBytes: Int64?
    /// When set, the device reports a wrong checksum, simulating a corrupt copy.
    var corruptChecksum = false
    /// When false, the device has no `sha256sum`, as on some minimal ROMs.
    var hasChecksumTool = true
    var truncateSupported = true
    var chunkSize = 64 * 1024

    private(set) var readCallCount = 0
    private(set) var lastReadOffset: Int64 = 0

    private(set) var checksumCallCount = 0
    /// How many paths each batched hash call was asked for, in order. A folder
    /// of small files should produce one large entry rather than many of one.
    private(set) var checksumBatchSizes: [Int] = []

    /// Stands in for `adb pull`: a bulk path faster than streaming.
    var supportsFastPull = false
    private(set) var fastPullCallCount = 0
    /// Slows the bulk path so a pause can land in the middle of it.
    var fastPullDelay: Duration = .zero

    init(kind: TransportKind = .adb, capabilities: TransportCapabilities? = nil) {
        self.kind = kind
        let resolved = capabilities ?? TransportCapabilities(
            supportsRangedReads: true, supportsResumableWrites: true,
            supportsDeviceSideChecksum: true, supportsMtimePreservation: true,
            reportsAccurateSizes: true, maximumConcurrentStreams: 4
        )
        self.configuredCapabilities = resolved
        self.capabilitiesBox = CapabilitiesBox(resolved)
    }

    // MARK: - Test controls

    func addFile(_ path: String, contents: Data, modified: Date? = nil) {
        files[path] = contents
        modificationDates[path] = modified
        var current = RemotePath(path).parent
        while let directory = current {
            directories.insert(directory.string)
            current = directory.parent
        }
    }

    func setFailReadAfterBytes(_ value: Int64?) { failReadAfterBytes = value }
    func setSupportsFastPull(_ value: Bool) { supportsFastPull = value }
    func setFastPullDelay(_ value: Duration) { fastPullDelay = value }
    func setCorruptChecksum(_ value: Bool) { corruptChecksum = value }
    func setHasChecksumTool(_ value: Bool) { hasChecksumTool = value }
    func setTruncateSupported(_ value: Bool) { truncateSupported = value }
    func contents(of path: String) -> Data? { files[path] }
    func exists(_ path: String) -> Bool { files[path] != nil || directories.contains(path) }
    func allPaths() -> [String] { files.keys.sorted() }

    // MARK: - DeviceTransport

    func currentDevice() async throws -> Device {
        Device(id: "fake", displayName: "Fake Phone", transport: kind)
    }

    func connect() async throws {}
    func disconnect() async {}

    func volumes() async throws -> [StorageVolume] {
        [StorageVolume(id: "emulated", rawName: "Internal storage",
                       rootPath: RemotePath("/storage/emulated/0"),
                       totalBytes: 128_000_000_000, freeBytes: 64_000_000_000)]
    }

    func list(_ path: RemotePath) async throws -> [RemoteFile] {
        guard directories.contains(path.string) else {
            if files[path.string] != nil { throw TransferError.notADirectory(path) }
            throw TransferError.notFound(path)
        }
        var results: [RemoteFile] = []
        for directory in directories where RemotePath(directory).parent == path {
            results.append(RemoteFile(path: RemotePath(directory), kind: .directory))
        }
        for (filePath, data) in files where RemotePath(filePath).parent == path {
            results.append(RemoteFile(path: RemotePath(filePath), size: Int64(data.count),
                                      modified: modificationDates[filePath], kind: .file))
        }
        return results.sorted { $0.name < $1.name }
    }

    func stat(_ path: RemotePath) async throws -> RemoteFile? {
        if let data = files[path.string] {
            return RemoteFile(path: path, size: Int64(data.count),
                              modified: modificationDates[path.string], kind: .file)
        }
        if directories.contains(path.string) {
            return RemoteFile(path: path, kind: .directory)
        }
        return nil
    }

    func createDirectory(_ path: RemotePath) async throws {
        var current: RemotePath? = path
        while let directory = current, !directory.isRoot {
            directories.insert(directory.string)
            current = directory.parent
        }
    }

    func remove(_ path: RemotePath, recursive: Bool) async throws {
        if files.removeValue(forKey: path.string) != nil { return }
        guard directories.contains(path.string) else { throw TransferError.notFound(path) }
        if recursive {
            files = files.filter { !RemotePath($0.key).isDescendant(of: path) }
            directories = directories.filter { $0 != path.string && !RemotePath($0).isDescendant(of: path) }
        } else {
            directories.remove(path.string)
        }
    }

    func move(from source: RemotePath, to destination: RemotePath) async throws {
        guard let data = files.removeValue(forKey: source.string) else {
            throw TransferError.notFound(source)
        }
        files[destination.string] = data
        modificationDates[destination.string] = modificationDates.removeValue(forKey: source.string)
    }

    func freeSpace(for volume: StorageVolume) async throws -> FreeSpaceReport {
        FreeSpaceReport(reportedFreeBytes: volume.freeBytes, totalBytes: volume.totalBytes, isTrustworthy: true)
    }

    func readStream(_ path: RemotePath, range: ByteRange) async throws -> AsyncThrowingStream<Data, any Error> {
        guard let data = files[path.string] else { throw TransferError.notFound(path) }
        readCallCount += 1
        lastReadOffset = range.offset

        let slice = data.subdata(in: Int(range.offset)..<data.count)
        let limit = failReadAfterBytes
        let size = chunkSize

        return AsyncThrowingStream { continuation in
            var delivered: Int64 = 0
            var index = 0
            while index < slice.count {
                let end = Swift.min(index + size, slice.count)
                let chunk = slice.subdata(in: index..<end)
                if let limit, delivered + Int64(chunk.count) > limit {
                    let allowed = Int(limit - delivered)
                    if allowed > 0 {
                        continuation.yield(chunk.subdata(in: 0..<allowed))
                    }
                    continuation.finish(throwing: TransferError.deviceDisconnected(during: "read"))
                    return
                }
                continuation.yield(chunk)
                delivered += Int64(chunk.count)
                index = end
            }
            continuation.finish()
        }
    }

    func fastPull(_ path: RemotePath, to localURL: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> Bool {
        guard supportsFastPull else { return false }
        guard let data = files[path.string] else { throw TransferError.notFound(path) }
        fastPullCallCount += 1

        // Written in pieces so cancellation can land partway, as it would
        // during a real bulk copy.
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }

        var index = 0
        while index < data.count {
            try Task.checkCancellation()
            if fastPullDelay != .zero { try await Task.sleep(for: fastPullDelay) }
            let end = Swift.min(index + chunkSize, data.count)
            let chunk = data.subdata(in: index..<end)
            try handle.write(contentsOf: chunk)
            progress(Int64(chunk.count))
            index = end
        }
        return true
    }

    func writeFile(from localURL: URL, to path: RemotePath, destinationOffset: Int64,
                   progress: @escaping @Sendable (Int64) -> Void) async throws {
        let data = try Data(contentsOf: localURL)
        let payload = destinationOffset > 0
            ? data.subdata(in: Int(destinationOffset)..<data.count)
            : data
        var existing = destinationOffset > 0 ? (files[path.string] ?? Data()) : Data()
        existing.append(payload)
        files[path.string] = existing
        try await createDirectory(path.parent ?? .root)
        progress(Int64(payload.count))
    }

    func checksum(_ path: RemotePath, algorithm: ChecksumAlgorithm) async throws -> Checksum? {
        checksumCallCount += 1
        guard hasChecksumTool else { return nil }
        guard let data = files[path.string] else { throw TransferError.notFound(path) }
        return hash(data)
    }

    /// Hashes a list in one go, as `sha256sum` over many paths does.
    ///
    /// A path the device does not have is left out of the result rather than
    /// throwing, which is what a real batch does: one unreadable file must not
    /// cost the hashes of the others.
    func checksums(_ paths: [RemotePath], algorithm: ChecksumAlgorithm) async throws -> [RemotePath: Checksum] {
        checksumBatchSizes.append(paths.count)
        guard hasChecksumTool else { return [:] }
        var result: [RemotePath: Checksum] = [:]
        for path in paths {
            if let data = files[path.string] { result[path] = hash(data) }
        }
        return result
    }

    private func hash(_ data: Data) -> Checksum {
        if corruptChecksum {
            return Checksum(algorithm: .sha256, value: String(repeating: "0", count: 64))
        }
        var hasher = ChecksumHasher(algorithm: .sha256)
        hasher.update(data)
        return hasher.finalize()
    }

    func truncate(_ path: RemotePath, to length: Int64) async throws {
        guard truncateSupported else {
            throw TransferError.unsupported(operation: "Trimming a partial file", transport: kind)
        }
        guard let data = files[path.string] else { throw TransferError.notFound(path) }
        files[path.string] = data.subdata(in: 0..<Int(Swift.min(length, Int64(data.count))))
    }

    func setModificationDate(_ date: Date, at path: RemotePath) async throws {
        modificationDates[path.string] = date
    }
}

struct FakeResolver: TransportResolver {
    let transport: FakeTransport
    func transport(for deviceID: DeviceID) async throws -> any DeviceTransport { transport }
}

/// A resolver that refuses, standing in for an unplugged cable.
struct UnavailableResolver: TransportResolver {
    func transport(for deviceID: DeviceID) async throws -> any DeviceTransport {
        throw TransferError.deviceDisconnected(during: "resolve")
    }
}
