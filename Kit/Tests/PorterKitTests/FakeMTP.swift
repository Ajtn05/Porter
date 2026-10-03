import Foundation
@testable import PorterKit

/// A scripted bulk endpoint pair.
///
/// Reads come from a queue of blobs, each one standing for what a single bulk
/// transfer handed back. That is the level the framing bugs live at: a
/// container split across two reads, two containers arriving in one, and a
/// zero-length packet where a payload landed exactly on a packet boundary.
actor FakeMTPPipe: MTPPipe {
    nonisolated let maximumPacketSize: Int
    private var pending: [Data]
    private(set) var written: [Data] = []
    private(set) var isClosed = false
    private var pausedWriteLength: Int?
    private var pausedWrite: CheckedContinuation<Void, Never>?

    init(maximumPacketSize: Int = 512, reads: [Data] = []) {
        self.maximumPacketSize = maximumPacketSize
        self.pending = reads
    }

    func enqueue(_ blobs: Data...) { pending.append(contentsOf: blobs) }

    func write(_ data: Data) async throws {
        written.append(data)
        if pausedWriteLength == data.count {
            pausedWriteLength = nil
            await withCheckedContinuation { pausedWrite = $0 }
        }
    }

    func pauseNextWrite(ofLength length: Int) { pausedWriteLength = length }
    var hasPausedWrite: Bool { pausedWrite != nil }
    func resumeWrite() { pausedWrite?.resume(); pausedWrite = nil }

    func read(maximumLength: Int) async throws -> Data {
        guard !pending.isEmpty else { return Data() }
        let next = pending.removeFirst()
        guard next.count > maximumLength else { return next }
        pending.insert(Data(next.dropFirst(maximumLength)), at: 0)
        return Data(next.prefix(maximumLength))
    }

    func close() async { isClosed = true }

    /// Everything written, concatenated, for asserting on what went out.
    var writtenBytes: Data { written.reduce(into: Data()) { $0.append($1) } }
}

/// Builders for the bytes a device would send back.
enum MTPWire {
    static func container(type: MTPContainerType, code: UInt16,
                          transaction: UInt32, payload: Data) -> Data {
        var writer = MTPWriter()
        writer.raw(MTPContainerHeader(
            length: UInt32(MTPContainerHeader.byteCount + payload.count),
            type: type, code: code, transactionID: transaction
        ).encoded())
        writer.raw(payload)
        return writer.data
    }

    static func response(_ code: MTPResponseCode, transaction: UInt32,
                         parameters: [UInt32] = []) -> Data {
        var writer = MTPWriter()
        for parameter in parameters { writer.uint32(parameter) }
        return container(type: .response, code: code.rawValue,
                         transaction: transaction, payload: writer.data)
    }

    static func data(_ operation: MTPOperation, transaction: UInt32, payload: Data) -> Data {
        container(type: .data, code: operation.rawValue, transaction: transaction, payload: payload)
    }

    static func uint32Array(_ values: [UInt32]) -> Data {
        var writer = MTPWriter()
        writer.uint32(UInt32(values.count))
        for value in values { writer.uint32(value) }
        return writer.data
    }

    static func deviceInfo(operations: [MTPOperation],
                           manufacturer: String = "Samsung",
                           model: String = "SM-S901E",
                           serial: String = "R5CT502XWRL") -> Data {
        var writer = MTPWriter()
        writer.uint16(100)                      // StandardVersion
        writer.uint32(0x00000006)               // VendorExtensionID: MTP
        writer.uint16(100)                      // VendorExtensionVersion
        writer.string("microsoft.com: 1.0;")
        writer.uint16(0)                        // FunctionalMode
        writer.uint32(UInt32(operations.count))
        for operation in operations { writer.uint16(operation.rawValue) }
        writer.uint32(0)                        // EventsSupported
        writer.uint32(0)                        // DevicePropertiesSupported
        writer.uint32(0)                        // CaptureFormats
        writer.uint32(0)                        // ImageFormats
        writer.string(manufacturer)
        writer.string(model)
        writer.string("1.0")
        writer.string(serial)
        return writer.data
    }

    static func storageInfo(storageType: UInt16 = 0x0003, description: String,
                            capacity: UInt64, free: UInt64) -> Data {
        var writer = MTPWriter()
        writer.uint16(storageType)
        writer.uint16(0x0002)                   // Generic hierarchical
        writer.uint16(0x0000)                   // Read-write
        writer.uint64(capacity)
        writer.uint64(free)
        writer.uint32(0xFFFF_FFFF)              // FreeSpaceInImages
        writer.string(description)
        writer.string("")                       // VolumeIdentifier
        return writer.data
    }

    /// The two exchanges `MTPSession.open()` performs, in order.
    static func openHandshake(operations: [MTPOperation] = [.getObjectPropList, .setObjectPropValue,
                                                            .moveObject, .getObjectPropValue]) -> [Data] {
        [
            data(.getDeviceInfo, transaction: 0, payload: deviceInfo(operations: operations)),
            response(.ok, transaction: 0),
            response(.ok, transaction: 0)
        ]
    }
}

/// An in-memory MTP responder, one level above the wire.
///
/// Where `FakeMTPPipe` exercises framing, this exercises the thing that has no
/// equivalent in any other transport: turning `/65537/DCIM/Camera/x.jpg` into a
/// numbered handle. It counts round trips, because on MTP the number of them is
/// the whole performance story.
actor FakeMTPBackend: MTPBackend {
    var objects: [UInt32: MTPObject] = [:]
    var contents: [UInt32: Data] = [:]
    var thumbnails: [UInt32: Data] = [:]
    private(set) var thumbnailCalls = 0
    var storages: [UInt32: MTPStorageInfo] = [:]
    var supportsPropertyLists = true
    var refusesPushesAsFull = false
    var storedDeviceInfo: MTPDeviceInfo?

    private(set) var handleListings = 0
    private(set) var objectInfoCalls = 0
    private(set) var propertyListCalls = 0
    private(set) var sizeCalls = 0
    private(set) var deletedHandles: [UInt32] = []
    private(set) var renamed: [(handle: UInt32, name: String)] = []
    private(set) var movedTo: [(handle: UInt32, parent: UInt32)] = []
    private(set) var createdFolders: [(name: String, parent: UInt32)] = []
    private(set) var sentObjects: [(name: String, size: Int64)] = []
    private var nextHandle: UInt32 = 1000

    init(storageID: UInt32 = 65537, capacity: Int64 = 120_000_000_000, free: Int64 = 2_500_000_000) {
        storages[storageID] = MTPStorageInfo(
            storageType: 0x0003, filesystemType: 0x0002, accessCapability: 0,
            maxCapacity: capacity, freeSpaceInBytes: free,
            description: "Internal storage", volumeIdentifier: ""
        )
        storedDeviceInfo = MTPDeviceInfo(
            standardVersion: 100, vendorExtensionID: 6,
            vendorExtensionDescription: "microsoft.com: 1.0;",
            operationsSupported: Set([MTPOperation.getObjectPropList, .setObjectPropValue,
                                      .moveObject, .getObjectPropValue].map(\.rawValue)),
            manufacturer: "Samsung", model: "SM-S901E", deviceVersion: "1.0",
            serialNumber: "R5CT502XWRL"
        )
    }

    // MARK: Building a tree

    @discardableResult
    func addFolder(_ name: String, parent: UInt32 = MTPHandle.root, storage: UInt32 = 65537) -> UInt32 {
        nextHandle += 1
        objects[nextHandle] = MTPObject(handle: nextHandle, parentHandle: parent, storageID: storage,
                                        name: name, size: 0, isFolder: true)
        return nextHandle
    }

    @discardableResult
    func addFile(_ name: String, parent: UInt32, storage: UInt32 = 65537,
                 bytes: Data = Data(), size: Int64? = nil, modified: Date? = nil) -> UInt32 {
        nextHandle += 1
        objects[nextHandle] = MTPObject(handle: nextHandle, parentHandle: parent, storageID: storage,
                                        name: name, size: size ?? Int64(bytes.count),
                                        modified: modified, isFolder: false)
        contents[nextHandle] = bytes
        return nextHandle
    }

    func removeAllStorages() { storages.removeAll() }
    func setPropertyListSupport(_ enabled: Bool) { supportsPropertyLists = enabled }
    func setStoreFull(_ full: Bool) { refusesPushesAsFull = full }

    // MARK: MTPBackend

    func open() async throws {}
    func close() async {}

    var deviceInfo: MTPDeviceInfo? { storedDeviceInfo }

    func supports(_ operation: MTPOperation) -> Bool {
        storedDeviceInfo?.supports(operation) ?? false
    }

    func storageIDs() async throws -> [UInt32] { storages.keys.sorted() }

    func storageInfo(_ id: UInt32) async throws -> MTPStorageInfo {
        guard let info = storages[id] else { throw TransferError.notFound(RemotePath("/\(id)")) }
        return info
    }

    func objectHandles(storage: UInt32, parent: UInt32) async throws -> [UInt32] {
        handleListings += 1
        return children(of: parent, storage: storage).map(\.handle)
    }

    func objectInfo(_ handle: UInt32, path: RemotePath?) async throws -> MTPObjectInfo {
        objectInfoCalls += 1
        guard let object = objects[handle] else { throw TransferError.notFound(path ?? .root) }
        return MTPObjectInfo(
            storageID: object.storageID,
            objectFormat: object.isFolder ? MTPObjectFormat.association : MTPObjectFormat.undefined,
            // Mirrors the real dataset: a size at or past the 32-bit ceiling
            // cannot be expressed here at all.
            size: object.size >= Int64(UInt32.max) ? nil : object.size,
            parentHandle: object.parentHandle,
            associationType: object.isFolder ? MTPAssociation.genericFolder : 0,
            filename: object.name,
            dateModified: object.modified.map { MTPDate.format($0) } ?? ""
        )
    }

    func setThumbnail(_ data: Data, for handle: UInt32) { thumbnails[handle] = data }
    func thumbnail(_ handle: UInt32, path: RemotePath?) async throws -> Data? {
        thumbnailCalls += 1
        return thumbnails[handle]
    }

    func objectSize(_ handle: UInt32, path: RemotePath?) async throws -> Int64? {
        sizeCalls += 1
        return objects[handle]?.size
    }

    func children(ofParent parent: UInt32, storage: UInt32, path: RemotePath?) async throws -> [MTPObject]? {
        guard supportsPropertyLists else { return nil }
        propertyListCalls += 1
        return children(of: parent, storage: storage)
    }

    func readObject(handle: UInt32, path: RemotePath?,
                    onChunk: @escaping @Sendable (Data) async throws -> Void) async throws {
        guard let data = contents[handle] else { throw TransferError.notFound(path ?? .root) }
        // Delivered in two pieces, so a consumer that only handles one chunk
        // fails the test rather than passing by accident.
        let split = data.count / 2
        try await onChunk(Data(data.prefix(split)))
        try await onChunk(Data(data.dropFirst(split)))
    }

    func readPartialObject(handle: UInt32, offset: Int64, length: Int64, path: RemotePath?,
                           onChunk: @escaping @Sendable (Data) async throws -> Void) async throws {
        guard supports(.getPartialObject64) || supports(.getPartialObject) else {
            throw TransferError.unsupported(operation: "Resuming a copy", transport: .mtp)
        }
        guard let data = contents[handle] else { throw TransferError.notFound(path ?? .root) }
        let start = Int(Swift.min(offset, Int64(data.count)))
        let end = Int(Swift.min(Int64(start) + length, Int64(data.count)))
        try await onChunk(Data(data[start ..< end]))
    }

    func sendObject(info: MTPObjectInfo, from url: URL, size: Int64, path: RemotePath?,
                    progress: @escaping @Sendable (Int64) -> Void) async throws -> UInt32 {
        if refusesPushesAsFull {
            // What the wire actually carries: a StoreFull response code, with
            // no numbers attached to it at all.
            throw TransferError.insufficientSpace(needed: 0, available: 0, volume: "/")
        }
        nextHandle += 1
        objects[nextHandle] = MTPObject(handle: nextHandle, parentHandle: info.parentHandle,
                                        storageID: info.storageID, name: info.filename,
                                        size: size, isFolder: false)
        contents[nextHandle] = (try? Data(contentsOf: url)) ?? Data()
        sentObjects.append((info.filename, size))
        progress(size)
        return nextHandle
    }

    func deleteObject(_ handle: UInt32, path: RemotePath?) async throws {
        deletedHandles.append(handle)
        // Android takes the contents with it, and so does this.
        var doomed = [handle]
        while let next = doomed.popLast() {
            objects[next] = nil
            contents[next] = nil
            doomed.append(contentsOf: objects.values.filter { $0.parentHandle == next }.map(\.handle))
        }
    }

    func createFolder(named name: String, parent: UInt32, storage: UInt32,
                      path: RemotePath?) async throws -> UInt32 {
        createdFolders.append((name, parent))
        return addFolder(name, parent: parent, storage: storage)
    }

    func moveObject(_ handle: UInt32, toParent parent: UInt32, storage: UInt32,
                    path: RemotePath?) async throws {
        movedTo.append((handle, parent))
        objects[handle]?.parentHandle = parent
    }

    func renameObject(_ handle: UInt32, to name: String, path: RemotePath?) async throws {
        renamed.append((handle, name))
        objects[handle]?.name = name
    }

    func setModified(_ date: Date, handle: UInt32, path: RemotePath?) async throws {
        objects[handle]?.modified = date
    }

    private func children(of parent: UInt32, storage: UInt32) -> [MTPObject] {
        objects.values
            .filter { $0.parentHandle == parent && $0.storageID == storage }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
