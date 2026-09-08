import Foundation

/// What a given pipe can actually do.
///
/// The engine reads this instead of switching on `TransportKind`, so adding a
/// transport never means hunting for `if kind == .mtp` scattered through the
/// copy loop. Being explicit about the weaknesses is the point: MTP genuinely
/// cannot seek, and pretending otherwise is how you get silently truncated files.
public struct TransportCapabilities: Hashable, Sendable {
    /// Can read from a byte offset, so an interrupted copy can resume.
    public var supportsRangedReads: Bool
    /// Can write from a byte offset, or emulate it well enough to resume.
    public var supportsResumableWrites: Bool
    /// Can hash a file on the device, so we can verify without pulling it twice.
    public var supportsDeviceSideChecksum: Bool
    /// Can set an mtime on a file it just received.
    public var supportsMtimePreservation: Bool
    /// Whether file sizes and free space from this transport can be believed.
    public var reportsAccurateSizes: Bool
    /// How many transfers may run at once before the transport degrades.
    /// MTP is a strictly serial protocol; running two streams makes it slower.
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

    /// Cheap, repeatable. Re-reading identity is how we notice a phone was
    /// unlocked or switched out of charge-only mode.
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

    /// Copies a whole file to `localURL` using whatever native bulk path the
    /// transport has, returning false if it has none.
    ///
    /// This exists because a transport's streaming interface and its bulk copy
    /// are often not the same speed. Measured on a Galaxy S22 over USB:
    /// `adb pull` sustains 37.6 MB/s where `adb exec-out cat` manages 15.7 MB/s
    /// for the same file. Streaming is what makes resume possible, so it stays
    /// - but a fresh copy should not pay for a feature it is not using.
    func fastPull(
        _ path: RemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Bool

    /// Copies a local file onto the device.
    ///
    /// Takes a URL rather than a stream because every transport we have can push
    /// a file far more efficiently than it can consume an arbitrary byte stream,
    /// and one side of a transfer is always the Mac.
    ///
    /// `destinationOffset > 0` requires `capabilities.supportsResumableWrites`
    /// and means "append these bytes to what is already there".
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
    /// Needed to resume a push: the sidecar may end in a half-written block, and
    /// appending to a partial block would corrupt the file silently. A transport
    /// that cannot do this throws, and the engine restarts the file instead.
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

    /// No native bulk path by default; the engine streams instead.
    func fastPull(_ path: RemotePath, to localURL: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> Bool {
        false
    }

    /// Recursive walk shared by every transport, so directory copy semantics are
    /// identical no matter which pipe is underneath.
    /// Directories are yielded before their contents, which is what a copy needs.
    func walk(_ root: RemotePath, includeHidden: Bool = true) async throws -> [RemoteFile] {
        var results: [RemoteFile] = []
        var queue: [RemotePath] = [root]
        // Guards against the symlink loops that /sdcard is full of
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
