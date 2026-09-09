import Foundation

/// Speaks PTP/MTP to the device.
///
/// Behind a protocol so the transport's semantics are written and tested once,
/// independently of whether the bytes are moved by `MTPSession` over USB, by
/// libmtp, or by a system framework. `MTPSession` is the implementation this
/// app ships; the seam is what lets every path-to-handle rule below be tested
/// against a fake without a phone on the end of a cable.
public protocol MTPBackend: Sendable {
    func open() async throws
    func close() async

    var deviceInfo: MTPDeviceInfo? { get async }
    func supports(_ operation: MTPOperation) async -> Bool

    func storageIDs() async throws -> [UInt32]
    func storageInfo(_ id: UInt32) async throws -> MTPStorageInfo

    func objectHandles(storage: UInt32, parent: UInt32) async throws -> [UInt32]
    func objectInfo(_ handle: UInt32, path: RemotePath?) async throws -> MTPObjectInfo
    func objectSize(_ handle: UInt32, path: RemotePath?) async throws -> Int64?
    /// One transaction for a whole folder, or nil when the device cannot answer
    /// that way and the caller should walk the handles one at a time.
    func children(ofParent parent: UInt32, storage: UInt32, path: RemotePath?) async throws -> [MTPObject]?

    func readObject(handle: UInt32, path: RemotePath?,
                    onChunk: @escaping @Sendable (Data) async throws -> Void) async throws
    func readPartialObject(handle: UInt32, offset: Int64, length: Int64, path: RemotePath?,
                           onChunk: @escaping @Sendable (Data) async throws -> Void) async throws
    func sendObject(info: MTPObjectInfo, from url: URL, size: Int64, path: RemotePath?,
                    progress: @escaping @Sendable (Int64) -> Void) async throws -> UInt32
    func deleteObject(_ handle: UInt32, path: RemotePath?) async throws
    func createFolder(named name: String, parent: UInt32, storage: UInt32,
                      path: RemotePath?) async throws -> UInt32
    func moveObject(_ handle: UInt32, toParent parent: UInt32, storage: UInt32,
                    path: RemotePath?) async throws
    func renameObject(_ handle: UInt32, to name: String, path: RemotePath?) async throws
    func setModified(_ date: Date, handle: UInt32, path: RemotePath?) async throws
}

extension MTPSession: MTPBackend {}

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

    public func remoteFile(in parent: RemotePath) -> RemoteFile {
        RemoteFile(
            path: parent.appending(name),
            size: size,
            modified: modified,
            kind: isFolder ? .directory : .file
        )
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
/// MTP has no paths, only numbered handles in a tree. Everything above this
/// line works in paths, so the mapping between the two lives here: a path is
/// `/<storage id>/folder/file`, its first component names a store, and the rest
/// is walked one level at a time and cached.
public actor MTPTransport: DeviceTransport {
    public nonisolated let kind: TransportKind = .mtp

    public nonisolated var capabilities: TransportCapabilities {
        TransportCapabilities(
            // GetPartialObject is in the spec, and `readStream` will use it when
            // a device offers it, but it is unreliable enough across shipped
            // Android MTP stacks that resume must not be promised up front.
            supportsRangedReads: false,
            supportsResumableWrites: false,
            supportsDeviceSideChecksum: false,
            // SetObjectPropValue on DateModified works on most phones and is
            // implemented below, but "most" is not a capability, so the engine
            // is told not to count on it.
            supportsMtimePreservation: false,
            reportsAccurateSizes: false,
            maximumConcurrentStreams: 1
        )
    }

    private var device: Device
    private let backend: (any MTPBackend)?

    /// The stores seen at the last `volumes()`, so an id in a path can be
    /// checked without another round trip.
    private var storagesByID: [UInt32: MTPStorage] = [:]
    /// Resolved objects by full path string. MTP charges a round trip per level
    /// of a walk, so resolving `/65537/DCIM/Camera/x.jpg` four times over should
    /// cost four transactions, not sixteen.
    private var objectsByPath: [String: MTPObject] = [:]

    public init(device: Device, backend: (any MTPBackend)? = nil) {
        self.device = device
        self.backend = backend
    }

    /// Convenience for the real thing: a session on top of a bulk pipe.
    public init(device: Device, pipe: any MTPPipe, options: MTPSession.Options = MTPSession.Options()) {
        self.device = device
        self.backend = MTPSession(pipe: pipe, deviceID: device.id, options: options)
    }

    private func requireBackend() throws -> any MTPBackend {
        guard let backend else { throw MTPTransport.unavailable }
        return backend
    }

    /// The error returned when no backend was wired up at all, which is a
    /// build-configuration problem rather than anything the device did.
    static var unavailable: TransferError {
        .transportUnavailable(
            .mtp,
            reason: "this build has no MTP engine attached. Turn on USB debugging to use the faster ADB transport, or pair over Wi-Fi."
        )
    }

    // MARK: - Lifecycle

    public func currentDevice() async throws -> Device {
        guard let backend, let info = await backend.deviceInfo else { return device }
        // MTP's DeviceInfo is the only identity a phone offers without USB
        // debugging, so it is worth folding back in: it is where the model name
        // in the sidebar comes from.
        if !info.manufacturer.isEmpty { device.manufacturer = info.manufacturer }
        if !info.model.isEmpty {
            device.model = info.model
            device.displayName = info.model
        }
        if !info.serialNumber.isEmpty { device.serial = info.serialNumber }
        device.lastSeen = Date()
        return device
    }

    public func connect() async throws {
        try await requireBackend().open()
    }

    public func disconnect() async {
        await backend?.close()
        storagesByID.removeAll()
        objectsByPath.removeAll()
    }

    // MARK: - Volumes

    public func volumes() async throws -> [StorageVolume] {
        let backend = try requireBackend()
        let ids = try await backend.storageIDs()
        // A locked Android phone enumerates over MTP and publishes no stores at
        // all. Reporting that as an empty device is what makes people think the
        // app cannot see their files; it is a locked screen, and the error says
        // so.
        guard !ids.isEmpty else {
            throw TransferError.deviceNotReady(device.id, .locked)
        }

        storagesByID.removeAll()
        var volumes: [StorageVolume] = []
        for id in ids {
            let info = try await backend.storageInfo(id)
            let storage = MTPStorage(
                id: id,
                description: info.description.isEmpty ? "Storage" : info.description,
                capacityBytes: info.maxCapacity,
                freeBytes: info.freeSpaceInBytes,
                isRemovable: info.isRemovable
            )
            storagesByID[id] = storage
            volumes.append(StorageVolume(
                id: String(id),
                rawName: storage.description,
                rootPath: RemotePath("/\(id)"),
                totalBytes: storage.capacityBytes,
                freeBytes: storage.freeBytes,
                isRemovable: storage.isRemovable,
                // MTP's FilesystemType field only distinguishes flat from
                // hierarchical, which says nothing about FAT32 and its 4 GiB
                // ceiling. Claiming to know would be worse than admitting not
                // to: the engine skips the ceiling check rather than enforcing
                // a guessed one.
                filesystem: .unknown,
                // MTP free-space figures are stale often enough that the engine
                // probes before a large copy.
                freeSpaceIsTrustworthy: false
            ))
        }
        return volumes.disambiguated()
    }

    public func freeSpace(for volume: StorageVolume) async throws -> FreeSpaceReport {
        guard let backend, let id = UInt32(volume.id) else {
            return FreeSpaceReport(reportedFreeBytes: volume.freeBytes,
                                   totalBytes: volume.totalBytes, isTrustworthy: false)
        }
        let info = try await backend.storageInfo(id)
        return FreeSpaceReport(
            reportedFreeBytes: info.freeSpaceInBytes,
            totalBytes: info.maxCapacity,
            isTrustworthy: false
        )
    }

    // MARK: - Path resolution

    private enum Location {
        /// The level above every volume. Exists so a browser opened at `/` has
        /// something to show; MTP itself has no such node.
        case deviceRoot
        /// The top of one store, which is a folder with no object of its own.
        case storageRoot(UInt32)
        /// The object, and the path spelled the way the device spells it, which
        /// is not always the way it was asked for.
        case object(MTPObject, canonicalPath: RemotePath)
    }

    private func resolve(_ path: RemotePath) async throws -> Location {
        guard !path.isRoot else { return .deviceRoot }
        guard let storage = UInt32(path.components[0]) else {
            throw TransferError.notFound(path)
        }
        guard path.components.count > 1 else { return .storageRoot(storage) }

        var currentPath = RemotePath(components: [path.components[0]])
        var currentHandle = MTPHandle.root

        for component in path.components.dropFirst() {
            let childPath = currentPath.appending(component)
            if let cached = objectsByPath[childPath.string] {
                currentPath = childPath
                currentHandle = cached.handle
                continue
            }
            let children = try await loadChildren(of: currentPath, parentHandle: currentHandle,
                                                  storage: storage)
            // Exact spelling first. Android's storage is case-preserving but
            // case-insensitive in practice, so a path typed with the wrong case
            // should find the file rather than report it missing.
            guard let match = children.first(where: { $0.name == component })
                ?? children.first(where: {
                    $0.name.compare(component, options: .caseInsensitive) == .orderedSame
                }) else {
                throw TransferError.notFound(childPath)
            }
            currentPath = currentPath.appending(match.name)
            currentHandle = match.handle
        }

        guard let object = objectsByPath[currentPath.string] else {
            throw TransferError.notFound(path)
        }
        return .object(object, canonicalPath: currentPath)
    }

    /// The store and folder handle a path names, for anything that writes into
    /// it.
    private func container(of path: RemotePath) async throws -> (storage: UInt32, handle: UInt32) {
        switch try await resolve(path) {
        case .deviceRoot:
            throw TransferError.unsupported(operation: "Writing above a volume", transport: .mtp)
        case .storageRoot(let storage):
            return (storage, MTPHandle.root)
        case .object(let object, _):
            guard object.isFolder else { throw TransferError.notADirectory(path) }
            return (object.storageID, object.handle)
        }
    }

    private func loadChildren(of path: RemotePath, parentHandle: UInt32,
                              storage: UInt32) async throws -> [MTPObject] {
        let backend = try requireBackend()

        if let batch = try await backend.children(ofParent: parentHandle, storage: storage, path: path) {
            cache(batch, under: path)
            return batch
        }

        // The slow path: one round trip for the handles, then one per object.
        // Correct everywhere, and the only option on a device that cannot
        // answer a property list.
        let handles = try await backend.objectHandles(storage: storage, parent: parentHandle)
        var objects: [MTPObject] = []
        objects.reserveCapacity(handles.count)
        for handle in handles {
            try Task.checkCancellation()
            let info = try await backend.objectInfo(handle, path: path)
            // A nil size means the 32-bit field could not hold it, so the real
            // figure has to come from the 64-bit property.
            var size = info.size
            if size == nil {
                size = try? await backend.objectSize(handle, path: path)
            }
            objects.append(MTPObject(
                handle: handle,
                parentHandle: info.parentHandle,
                storageID: info.storageID == 0 ? storage : info.storageID,
                name: info.filename,
                size: size ?? 0,
                modified: MTPDate.parse(info.dateModified),
                isFolder: info.isFolder
            ))
        }
        let sorted = objects
            .filter { !$0.name.isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cache(sorted, under: path)
        return sorted
    }

    private func cache(_ objects: [MTPObject], under path: RemotePath) {
        for object in objects {
            objectsByPath[path.appending(object.name).string] = object
        }
    }

    /// Drops `path` and everything beneath it, after a change that invalidates
    /// the handles under it.
    private func invalidate(_ path: RemotePath) {
        let prefix = path.string
        objectsByPath = objectsByPath.filter {
            $0.key != prefix && !$0.key.hasPrefix(prefix == "/" ? "/" : prefix + "/")
        }
    }

    // MARK: - Browsing

    public func list(_ path: RemotePath) async throws -> [RemoteFile] {
        switch try await resolve(path) {
        case .deviceRoot:
            return try await volumes().map {
                RemoteFile(path: $0.rootPath, kind: .directory)
            }
        case .storageRoot(let storage):
            return try await loadChildren(of: path, parentHandle: MTPHandle.root, storage: storage)
                .map { $0.remoteFile(in: path) }
        case .object(let object, let canonical):
            guard object.isFolder else { throw TransferError.notADirectory(path) }
            return try await loadChildren(of: canonical, parentHandle: object.handle,
                                          storage: object.storageID)
                .map { $0.remoteFile(in: canonical) }
        }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteFile? {
        do {
            switch try await resolve(path) {
            case .deviceRoot, .storageRoot:
                return RemoteFile(path: path, kind: .directory)
            case .object(let object, let canonical):
                // Reported under the device's own spelling, not the caller's.
                return object.remoteFile(in: canonical.parent ?? .root)
            }
        } catch TransferError.notFound {
            return nil
        }
    }

    // MARK: - Mutating the device

    public func createDirectory(_ path: RemotePath) async throws {
        let backend = try requireBackend()
        guard let parent = path.parent else {
            throw TransferError.unsupported(operation: "Creating a volume", transport: .mtp)
        }
        let destination = try await container(of: parent)
        _ = try await backend.createFolder(named: path.name, parent: destination.handle,
                                           storage: destination.storage, path: path)
        invalidate(parent)
    }

    public func remove(_ path: RemotePath, recursive: Bool) async throws {
        let backend = try requireBackend()
        switch try await resolve(path) {
        case .deviceRoot, .storageRoot:
            throw TransferError.unsupported(operation: "Deleting a volume", transport: .mtp)
        case .object(let object, let canonical):
            if object.isFolder, !recursive {
                // DeleteObject on a folder always takes the contents with it, so
                // a non-recursive delete of a folder that has any is not
                // something this protocol can do.
                let children = try await loadChildren(of: canonical, parentHandle: object.handle,
                                                      storage: object.storageID)
                guard children.isEmpty else {
                    throw TransferError.unsupported(
                        operation: "Deleting a folder without its contents", transport: .mtp)
                }
            }
            try await backend.deleteObject(object.handle, path: path)
            invalidate(canonical)
        }
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        let backend = try requireBackend()
        guard case .object(let object, let canonicalSource) = try await resolve(source) else {
            throw TransferError.unsupported(operation: "Moving a volume", transport: .mtp)
        }
        let sourceParent = source.parent ?? .root
        let destinationParent = destination.parent ?? .root

        if sourceParent == destinationParent {
            // MTP has no rename operation. The filename is a property, and
            // setting it is the rename. That is also how the engine's
            // `.porterpart` sidecar becomes the finished file.
            try await backend.renameObject(object.handle, to: destination.name, path: destination)
        } else {
            let target = try await container(of: destinationParent)
            guard target.storage == object.storageID else {
                // MoveObject between stores is in the spec and refused by most
                // phones. Saying so lets the engine fall back to copy-then-
                // delete instead of retrying something that cannot work.
                throw TransferError.unsupported(operation: "Moving a file between volumes",
                                                transport: .mtp)
            }
            try await backend.moveObject(object.handle, toParent: target.handle,
                                         storage: target.storage, path: destination)
            if destination.name != source.name {
                try await backend.renameObject(object.handle, to: destination.name, path: destination)
            }
        }
        invalidate(canonicalSource)
        invalidate(sourceParent)
        invalidate(destinationParent)
    }

    // MARK: - Bytes

    public func readStream(_ path: RemotePath, range: ByteRange) async throws -> AsyncThrowingStream<Data, any Error> {
        let backend = try requireBackend()
        guard case .object(let object, _) = try await resolve(path) else {
            throw TransferError.notADirectory(path)
        }
        guard !object.isFolder else { throw TransferError.notADirectory(path) }

        let handle = object.handle
        let offset = range.offset
        let length = range.length ?? Swift.max(0, object.size - offset)
        let wantsWholeFile = range.isWholeFile

        return AsyncThrowingStream { continuation in
            // Unbuffered yield, as the ADB transport does: MTP delivers well
            // under what the local disk absorbs, so the consumer is never the
            // slow end and a bounded queue would only add a hop.
            let task = Task {
                let sink: @Sendable (Data) async throws -> Void = { chunk in
                    continuation.yield(chunk)
                }
                do {
                    if wantsWholeFile {
                        try await backend.readObject(handle: handle, path: path, onChunk: sink)
                    } else {
                        try await backend.readPartialObject(handle: handle, offset: offset,
                                                            length: length, path: path, onChunk: sink)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func writeFile(from localURL: URL, to path: RemotePath, destinationOffset: Int64,
                          progress: @escaping @Sendable (Int64) -> Void) async throws {
        let backend = try requireBackend()
        guard destinationOffset == 0 else {
            // SendObject writes from the beginning and nothing else. Refusing is
            // what makes the engine restart the file rather than append to a
            // partial one and produce a corrupt result that still verifies as
            // the right length.
            throw TransferError.unsupported(operation: "Resuming a copy onto the phone", transport: .mtp)
        }

        let parentPath = path.parent ?? .root
        let destination = try await container(of: parentPath)

        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes[.modificationDate] as? Date

        let info = MTPObjectInfo(
            storageID: destination.storage,
            objectFormat: MTPObjectFormat.undefined,
            size: size,
            parentHandle: destination.handle,
            filename: path.name,
            dateModified: modified.map { MTPDate.format($0) } ?? ""
        )

        do {
            _ = try await backend.sendObject(info: info, from: localURL, size: size,
                                             path: path, progress: progress)
        } catch TransferError.insufficientSpace {
            // The device only says "full", with no numbers in it. Asking again
            // now costs one round trip on a path that has already failed, and
            // buys a sentence with the actual figures in it.
            let cached = storagesByID[destination.storage]
            let fresh = try? await backend.storageInfo(destination.storage)
            throw TransferError.insufficientSpace(
                needed: size,
                available: fresh?.freeSpaceInBytes ?? cached?.freeBytes ?? 0,
                volume: fresh?.description ?? cached?.description ?? parentPath.string
            )
        }
        invalidate(parentPath)
    }

    public func checksum(_ path: RemotePath, algorithm: ChecksumAlgorithm) async throws -> Checksum? {
        // MTP has no device-side hashing. Returning nil rather than throwing
        // lets the engine fall back to its size check and mark the file
        // unverified.
        nil
    }

    public func setModificationDate(_ date: Date, at path: RemotePath) async throws {
        guard let backend else { return }
        guard case .object(let object, _) = try await resolve(path) else { return }
        do {
            try await backend.setModified(date, handle: object.handle, path: path)
        } catch TransferError.unsupported {
            // Best effort by design. `supportsMtimePreservation` is false, so
            // nothing upstream is relying on this having worked.
        }
    }
}
