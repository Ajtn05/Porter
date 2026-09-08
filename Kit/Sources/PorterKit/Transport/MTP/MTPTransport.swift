import Foundation

/// Speaks PTP/MTP to the device.
///
/// Behind a protocol so the transport's semantics are written and tested once,
/// independently of whether the bytes are moved by libmtp, a bundled libusb
/// implementation, or a system framework.
public protocol MTPBackend: Sendable {
    func openSession() async throws
    func closeSession() async
    func storageIDs() async throws -> [MTPStorage]
    func children(ofHandle handle: UInt32, storage: UInt32) async throws -> [MTPObject]
    func readObject(handle: UInt32, range: ByteRange) async throws -> AsyncThrowingStream<Data, any Error>
    func sendObject(from url: URL, name: String, parent: UInt32, storage: UInt32,
                    progress: @escaping @Sendable (Int64) -> Void) async throws -> UInt32
    func deleteObject(handle: UInt32) async throws
    func createFolder(named name: String, parent: UInt32, storage: UInt32) async throws -> UInt32
}

public struct MTPStorage: Hashable, Sendable {
    public var id: UInt32
    public var description: String
    public var capacityBytes: Int64
    public var freeBytes: Int64
    public var isRemovable: Bool

    public init(id: UInt32, description: String, capacityBytes: Int64, freeBytes: Int64, isRemovable: Bool) {
        self.id = id
        self.description = description
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
        self.isRemovable = isRemovable
    }
}

public struct MTPObject: Hashable, Sendable {
    public var handle: UInt32
    public var parentHandle: UInt32
    public var storageID: UInt32
    public var name: String
    public var size: Int64
    public var modified: Date?
    public var isFolder: Bool

    public init(handle: UInt32, parentHandle: UInt32, storageID: UInt32, name: String,
                size: Int64, modified: Date? = nil, isFolder: Bool) {
        self.handle = handle
        self.parentHandle = parentHandle
        self.storageID = storageID
        self.name = name
        self.size = size
        self.modified = modified
        self.isFolder = isFolder
    }
}

/// Fallback transport for phones with USB debugging switched off.
///
/// The capabilities below declare MTP's limits rather than working around them:
/// it is strictly serial, cannot hash a file on the device, reports stale
/// free-space figures, and often rounds or omits modification times. The engine
/// reads those flags and adapts, verifying by size alone, declining to promise
/// resume, and probing free space before a large copy.
///
/// - Note: The PTP/MTP wire implementation is not written. Every file operation
///   below reports that explicitly rather than failing opaquely. See
///   `Docs/status.md`.
public actor MTPTransport: DeviceTransport {
    public nonisolated let kind: TransportKind = .mtp

    public nonisolated var capabilities: TransportCapabilities {
        TransportCapabilities(
            // GetPartialObject is in the spec, but is unreliable enough in
            // shipped Android MTP stacks that resume cannot rely on it.
            supportsRangedReads: false,
            supportsResumableWrites: false,
            supportsDeviceSideChecksum: false,
            supportsMtimePreservation: false,
            reportsAccurateSizes: false,
            maximumConcurrentStreams: 1
        )
    }

    private var device: Device
    private let backend: (any MTPBackend)?

    public init(device: Device, backend: (any MTPBackend)? = nil) {
        self.device = device
        self.backend = backend
    }

    private func requireBackend() throws -> any MTPBackend {
        guard let backend else { throw MTPTransport.unavailable }
        return backend
    }

    /// The error every unimplemented path returns.
    static var unavailable: TransferError {
        .transportUnavailable(
            .mtp,
            reason: "this build has no MTP engine yet. Turn on USB debugging to use the faster ADB transport, or pair over Wi-Fi."
        )
    }

    public func currentDevice() async throws -> Device { device }

    public func connect() async throws {
        try await requireBackend().openSession()
    }

    public func disconnect() async {
        await backend?.closeSession()
    }

    public func volumes() async throws -> [StorageVolume] {
        let storages = try await requireBackend().storageIDs()
        return storages.map { storage in
            StorageVolume(
                id: String(storage.id),
                rawName: storage.description,
                rootPath: RemotePath("/\(storage.id)"),
                totalBytes: storage.capacityBytes,
                freeBytes: storage.freeBytes,
                isRemovable: storage.isRemovable,
                filesystem: .unknown,
                // MTP free-space figures are stale often enough that the
                // engine probes before a large copy.
                freeSpaceIsTrustworthy: false
            )
        }.disambiguated()
    }

    public func list(_ path: RemotePath) async throws -> [RemoteFile] { throw Self.unavailable }
    public func stat(_ path: RemotePath) async throws -> RemoteFile? { throw Self.unavailable }
    public func createDirectory(_ path: RemotePath) async throws { throw Self.unavailable }
    public func remove(_ path: RemotePath, recursive: Bool) async throws { throw Self.unavailable }
    public func move(from source: RemotePath, to destination: RemotePath) async throws { throw Self.unavailable }

    public func freeSpace(for volume: StorageVolume) async throws -> FreeSpaceReport {
        FreeSpaceReport(
            reportedFreeBytes: volume.freeBytes,
            totalBytes: volume.totalBytes,
            isTrustworthy: false
        )
    }

    public func readStream(_ path: RemotePath, range: ByteRange) async throws -> AsyncThrowingStream<Data, any Error> {
        throw Self.unavailable
    }

    public func writeFile(from localURL: URL, to path: RemotePath, destinationOffset: Int64,
                          progress: @escaping @Sendable (Int64) -> Void) async throws {
        throw Self.unavailable
    }

    public func checksum(_ path: RemotePath, algorithm: ChecksumAlgorithm) async throws -> Checksum? {
        // MTP has no device-side hashing. Returning nil rather than throwing
        // lets the engine fall back to its size check and mark the file
        // unverified.
        nil
    }

    public func setModificationDate(_ date: Date, at path: RemotePath) async throws {}
}
