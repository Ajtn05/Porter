import Foundation

/// The operations a transport supports.
///
/// The engine reads these flags instead of switching on `TransportKind`, so
/// adding a transport does not mean revisiting the copy loop. The limits are
/// declared rather than inferred: MTP cannot seek, and treating it as if it
/// could produces silently truncated files.
public struct TransportCapabilities: Hashable, Sendable {
    /// Can read from a byte offset, so an interrupted copy can resume.
    public var supportsRangedReads: Bool
    /// Can write from a byte offset, or emulate it well enough to resume.
    public var supportsResumableWrites: Bool
    /// Can hash a file on the device, so verification needs no second transfer.
    public var supportsDeviceSideChecksum: Bool
    /// Can set an mtime on a file it just received.
    public var supportsMtimePreservation: Bool
    /// Whether file sizes and free space reported by this transport are reliable.
    public var reportsAccurateSizes: Bool
    /// How many transfers may run at once before the transport degrades. MTP is
    /// strictly serial, so a second stream makes it slower.
    public var maximumConcurrentStreams: Int

    public init(supportsRangedReads: Bool, supportsResumableWrites: Bool,
                supportsDeviceSideChecksum: Bool, supportsMtimePreservation: Bool,
                reportsAccurateSizes: Bool, maximumConcurrentStreams: Int) {
        self.supportsRangedReads = supportsRangedReads
        self.supportsResumableWrites = supportsResumableWrites
        self.supportsDeviceSideChecksum = supportsDeviceSideChecksum
        self.supportsMtimePreservation = supportsMtimePreservation
        self.reportsAccurateSizes = reportsAccurateSizes
        self.maximumConcurrentStreams = maximumConcurrentStreams
    }
}

/// The one abstraction the rest of the app talks to.
///
/// The user picks a device, not a protocol; everything above this line is
/// written once and works over cable or Wi-Fi.
public protocol DeviceTransport: Sendable {
    var kind: TransportKind { get }
    var capabilities: TransportCapabilities { get }

    /// Re-reads the device's identity and readiness. Cheap and repeatable; this
    /// is how an unlock or a change out of charge-only mode is noticed.
    func currentDevice() async throws -> Device

    func connect() async throws
    func disconnect() async

    func volumes() async throws -> [StorageVolume]
    func list(_ path: RemotePath) async throws -> [RemoteFile]
    func stat(_ path: RemotePath) async throws -> RemoteFile?

    func createDirectory(_ path: RemotePath) async throws
    func remove(_ path: RemotePath, recursive: Bool) async throws
    func move(from source: RemotePath, to destination: RemotePath) async throws

    func freeSpace(for volume: StorageVolume) async throws -> FreeSpaceReport

    /// Streams bytes off the device. `range.offset > 0` requires
    /// `capabilities.supportsRangedReads`.
    func readStream(_ path: RemotePath, range: ByteRange) async throws -> AsyncThrowingStream<Data, any Error>

    /// Copies a whole file to `localURL` over the transport's native bulk path,
    /// returning false when it has none.
    ///
    /// A transport's streaming interface and its bulk copy are often not the
    /// same speed. Measured on a Galaxy S22 over USB, `adb pull` sustains
    /// 37.6 MB/s against 15.7 MB/s for `adb exec-out cat` on the same file.
    /// Streaming remains the path that supports resume.
    func fastPull(
        _ path: RemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Bool

    /// Copies a local file onto the device.
    ///
    /// Takes a URL rather than a stream because every transport pushes a file
    /// far more efficiently than it consumes an arbitrary byte stream, and one
    /// side of a transfer is always the Mac.
    ///
    /// A `destinationOffset` above zero appends to what is already there and
    /// requires `capabilities.supportsResumableWrites`.
    func writeFile(
        from localURL: URL,
        to path: RemotePath,
        destinationOffset: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws

    /// Hashes a file on the device without transferring it. Nil when the device
    /// has no suitable tool.
    func checksum(_ path: RemotePath, algorithm: ChecksumAlgorithm) async throws -> Checksum?

    /// Trims a file on the device to `length`.
    ///
    /// Required to resume a push: the sidecar may end in a half-written block,
    /// and appending to a partial block corrupts the file. Transports that
    /// cannot trim throw, and the engine restarts the file instead.
    func truncate(_ path: RemotePath, to length: Int64) async throws

    func setModificationDate(_ date: Date, at path: RemotePath) async throws
}

public extension DeviceTransport {
    func readStream(_ path: RemotePath) async throws -> AsyncThrowingStream<Data, any Error> {
        try await readStream(path, range: .whole)
    }

    func truncate(_ path: RemotePath, to length: Int64) async throws {
        throw TransferError.unsupported(operation: "Trimming a partial file", transport: kind)
    }

    /// No native bulk path by default, so the engine streams instead.
    func fastPull(_ path: RemotePath, to localURL: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> Bool {
        false
    }

    /// Recursively lists everything under `root`, yielding directories before
    /// their contents. Shared by every transport so directory copy semantics do
    /// not vary between them.
    func walk(_ root: RemotePath, includeHidden: Bool = true) async throws -> [RemoteFile] {
        var results: [RemoteFile] = []
        var queue: [RemotePath] = [root]
        // Guards against symlink loops, which /sdcard is full of
        // (/sdcard -> /storage/self/primary -> /storage/emulated/0).
        var visited: Set<String> = []

        while let path = queue.first {
            queue.removeFirst()
            guard visited.insert(path.string).inserted else { continue }
            let entries = try await list(path)
            for entry in entries where includeHidden || !entry.isHidden {
                results.append(entry)
                if entry.kind == .directory {
                    queue.append(entry.path)
                }
            }
            try Task.checkCancellation()
        }
        return results
    }
}
