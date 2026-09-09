import Foundation

/// The bulk channel underneath a session: one endpoint towards the phone, one
/// back.
///
/// Everything above this is pure protocol and is tested without hardware. Below
/// it sits whatever moves the bytes: IOKit today, something else later. That is
/// the only part that needs a phone on the end of a cable.
public protocol MTPPipe: Sendable {
    /// The bulk endpoint's `wMaxPacketSize`. A transfer that is an exact
    /// multiple of it is terminated by a zero-length packet, and a reader that
    /// does not expect one waits forever for bytes that are never coming.
    var maximumPacketSize: Int { get }

    func write(_ data: Data) async throws
    /// Reads one bulk transfer, returning short at the end of one and empty for
    /// a zero-length packet.
    func read(maximumLength: Int) async throws -> Data
    func close() async
}

/// A PTP/MTP session: transaction sequencing, the three-phase command/data/
/// response exchange, and the operations this app needs on top of it.
///
/// One session is strictly serial by design, not by omission. MTP has a single
/// transaction in flight at a time and a device given a second one while the
/// first is open will either stall or answer the wrong question, which is why
/// `MTPTransport` declares `maximumConcurrentStreams: 1`.
///
/// Being an actor is not what enforces that, though it reads as if it should.
/// An actor gives up its isolation at every suspension, and a transaction
/// suspends at each read and each write, so a second call can begin between two
/// packets of the first. `transact` holds an explicit gate for the length of a
/// whole exchange, and that is what makes the serialisation real.
public actor MTPSession {
    public struct Options: Sendable {
        public var sessionID: UInt32
        public var readChunkSize: Int
        public var writeChunkSize: Int
        /// MTP timestamps carry no zone, and the spec reads an unmarked one as
        /// the device's local time. There is no way to ask the phone what that
        /// is, so the Mac's zone stands in.
        public var deviceTimeZone: TimeZone

        public init(sessionID: UInt32 = 1,
                    readChunkSize: Int = 512 * 1024,
                    writeChunkSize: Int = 512 * 1024,
                    deviceTimeZone: TimeZone = .current) {
            self.sessionID = sessionID
            self.readChunkSize = readChunkSize
            self.writeChunkSize = writeChunkSize
            self.deviceTimeZone = deviceTimeZone
        }
    }

    public struct TransactionResult: Sendable {
        public var parameters: [UInt32]
        public var data: Data
    }

    private let pipe: any MTPPipe
    private let deviceID: DeviceID
    private let options: Options

    /// Transaction 0 is reserved for the two operations that are legal outside a
    /// session; everything inside one starts at 1 and increments.
    private var nextTransactionID: UInt32 = 1
    private var isOpen = false
    private var cachedDeviceInfo: MTPDeviceInfo?

    /// Bytes that arrived past the end of the container being read.
    ///
    /// A bulk read ends on a short packet, so a payload whose length is an exact
    /// multiple of the packet size has no short packet to end it and the next
    /// container can be delivered in the same read. Holding the excess here is
    /// what stops that from being mistaken for a corrupt response.
    private var pushback = Data()

    public init(pipe: any MTPPipe, deviceID: DeviceID, options: Options = Options()) {
        self.pipe = pipe
        self.deviceID = deviceID
        self.options = options
    }

    // MARK: - Session lifecycle

    public var deviceInfo: MTPDeviceInfo? { cachedDeviceInfo }

    public func open() async throws {
        guard !isOpen else { return }

        // GetDeviceInfo is legal before a session exists, and answering it is
        // the cheapest proof that the endpoints are actually wired to an MTP
        // responder rather than to something else that enumerated as one.
        nextTransactionID = 0
        let info = try await transact(.getDeviceInfo)
        cachedDeviceInfo = try MTPDeviceInfo.decode(info.data)

        // A session left open by a previous process answers
        // `SessionAlreadyOpen`, which the response mapping already treats as
        // success: a session was asked for, and there is one.
        nextTransactionID = 0
        _ = try await transact(.openSession, parameters: [options.sessionID])
        nextTransactionID = 1
        isOpen = true
    }

    public func close() async {
        guard isOpen else { return }
        _ = try? await transact(.closeSession)
        isOpen = false
        cachedDeviceInfo = nil
        pushback = Data()
        await pipe.close()
    }

    public func supports(_ operation: MTPOperation) -> Bool {
        cachedDeviceInfo?.supports(operation) ?? false
    }

    // MARK: - Transactions

    /// Held for a whole command/data/response exchange.
    ///
    /// `maximumConcurrentStreams: 1` binds the transfer engine, which is not
    /// the only thing that talks to a phone: browsing is driven straight from
    /// the UI, and clicking a second folder before the first has finished
    /// listing puts two transactions on one pipe. The reply to one is then read
    /// by the other, and it surfaces as a decode of an empty payload a step or
    /// two later rather than as anything naming the real cause.
    private var pipeIsBusy = false
    private var pipeWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquirePipe() async {
        while pipeIsBusy {
            await withCheckedContinuation { pipeWaiters.append($0) }
        }
        pipeIsBusy = true
    }

    private func releasePipe() {
        pipeIsBusy = false
        guard !pipeWaiters.isEmpty else { return }
        pipeWaiters.removeFirst().resume()
    }

    @discardableResult
    public func transact(
        _ operation: MTPOperation,
        parameters: [UInt32] = [],
        path: RemotePath? = nil,
        dataOut: Data? = nil,
        onDataIn: (@Sendable (Data) async throws -> Void)? = nil
    ) async throws -> TransactionResult {
        try Task.checkCancellation()

        await acquirePipe()
        defer { releasePipe() }

        let transaction = nextTransactionID
        nextTransactionID &+= 1

        try await pipe.write(MTPPacket.command(operation, transactionID: transaction,
                                               parameters: parameters))
        if let dataOut {
            try await pipe.write(MTPPacket.dataHeader(operation, transactionID: transaction,
                                                      payloadLength: Int64(dataOut.count)))
            if !dataOut.isEmpty { try await pipe.write(dataOut) }
        }

        var collected = Data()
        while true {
            let container = try await readContainer(operation: operation, path: path, sink: onDataIn)
            switch container.header.type {
            case .data:
                collected = container.payload
            case .response:
                let raw = container.header.code
                guard let code = MTPResponseCode(rawValue: raw) else {
                    throw TransferError.protocolError(
                        "\(operation.name) answered with \(MTPResponse.describe(raw: raw))")
                }
                if let error = MTPResponse.error(for: code, operation: operation,
                                                 path: path, device: deviceID) {
                    throw error
                }
                return TransactionResult(parameters: container.parameters, data: collected)
            case .event:
                // Events are unsolicited and arrive on their own endpoint on
                // most devices; one that lands here is not part of this
                // exchange and is dropped rather than mistaken for a response.
                continue
            case .command:
                throw TransferError.protocolError(
                    "the phone sent a command container in reply to \(operation.name)")
            }
        }
    }

    private struct Container {
        var header: MTPContainerHeader
        var payload: Data
        /// Response and command containers carry up to five 32-bit parameters
        /// in place of a payload.
        var parameters: [UInt32]
    }

    private func readContainer(
        operation: MTPOperation,
        path: RemotePath?,
        sink: (@Sendable (Data) async throws -> Void)?
    ) async throws -> Container {
        // Cancellation is honoured for a streaming data phase, where the
        // caller may be walking away from a large copy, and not for a metadata
        // exchange. Once a command has gone out the device is going to answer
        // it whether or not anyone is still listening, and MTP runs one
        // transaction at a time, so an abandoned reply stays in the pipe for
        // the next transaction to take as its own. The pipe's own read timeout
        // is what bounds the wait instead.
        let honoursCancellation = sink != nil

        var first = Data()
        var emptyReads = 0
        while first.isEmpty {
            emptyReads += 1
            // Zero-length packets are legitimate terminators, so a couple in a
            // row are expected. A stream of them is a wedged endpoint.
            guard emptyReads <= 8 else {
                throw TransferError.deviceStalled(
                    reason: "the phone answered \(operation.name) with nothing but empty packets")
            }
            if honoursCancellation { try Task.checkCancellation() }
            first = try await nextBytes(maximum: options.readChunkSize)
        }

        guard first.count >= MTPContainerHeader.byteCount else {
            throw TransferError.protocolError(
                "\(operation.name) came back in \(first.count) bytes, shorter than a container header")
        }

        let header = try MTPContainerHeader.decode(first)
        var payload = Data(first.dropFirst(MTPContainerHeader.byteCount))

        // Trim anything belonging to the next container and keep it for the
        // next read.
        if let expected = header.payloadLength, payload.count > expected {
            pushback = Data(payload.dropFirst(expected)) + pushback
            payload = Data(payload.prefix(expected))
        }

        // Only a data phase streams. A response's payload is five parameters at
        // most, so it is always accumulated.
        let streaming = header.type == .data && sink != nil
        var accumulated = Data()
        var received = payload.count
        if streaming {
            if !payload.isEmpty { try await sink!(payload) }
        } else {
            accumulated = payload
        }

        if let expected = header.payloadLength {
            while received < expected {
                if honoursCancellation { try Task.checkCancellation() }
                let chunk = try await nextBytes(maximum: min(options.readChunkSize, expected - received))
                guard !chunk.isEmpty else {
                    throw TransferError.truncated(
                        path: path?.string ?? operation.name,
                        expected: Int64(expected), actual: Int64(received))
                }
                received += chunk.count
                if streaming { try await sink!(chunk) } else { accumulated.append(chunk) }
            }
        } else {
            // The device declined to declare a length, which it does for large
            // objects. The transfer then ends on the first short packet.
            while true {
                if honoursCancellation { try Task.checkCancellation() }
                let chunk = try await nextBytes(maximum: options.readChunkSize)
                if chunk.isEmpty { break }
                received += chunk.count
                if streaming { try await sink!(chunk) } else { accumulated.append(chunk) }
                if chunk.count % pipe.maximumPacketSize != 0 { break }
            }
        }

        var parameters: [UInt32] = []
        if header.type == .response || header.type == .command {
            var reader = MTPReader(accumulated)
            while reader.remaining >= 4 {
                parameters.append(try reader.uint32("a response parameter"))
            }
        }

        return Container(header: header, payload: streaming ? Data() : accumulated,
                         parameters: parameters)
    }

    private func nextBytes(maximum: Int) async throws -> Data {
        guard maximum > 0 else { return Data() }
        if !pushback.isEmpty {
            let count = min(maximum, pushback.count)
            let head = Data(pushback.prefix(count))
            pushback = Data(pushback.dropFirst(count))
            return head
        }
        return try await pipe.read(maximumLength: maximum)
    }

    // MARK: - Storage

    public func storageIDs() async throws -> [UInt32] {
        let result = try await transact(.getStorageIDs)
        var reader = MTPReader(result.data)
        return try reader.uint32Array("StorageIDs")
    }

    public func storageInfo(_ id: UInt32) async throws -> MTPStorageInfo {
        let result = try await transact(.getStorageInfo, parameters: [id])
        return try MTPStorageInfo.decode(result.data)
    }

    // MARK: - Objects

    public func objectHandles(storage: UInt32, parent: UInt32) async throws -> [UInt32] {
        // The middle parameter is a format filter; zero means every format,
        // which is the only useful answer for a file browser.
        let result = try await transact(.getObjectHandles, parameters: [storage, 0, parent])
        var reader = MTPReader(result.data)
        return try reader.uint32Array("ObjectHandles")
    }

    public func objectInfo(_ handle: UInt32, path: RemotePath? = nil) async throws -> MTPObjectInfo {
        let result = try await transact(.getObjectInfo, parameters: [handle], path: path)
        return try MTPObjectInfo.decode(result.data)
    }

    /// The 64-bit size property, needed for anything four gigabytes or larger.
    ///
    /// `ObjectInfo` carries a 32-bit size field and nothing else, so without
    /// this a 6 GB video reports as whatever it is modulo 4 GiB, and the copy
    /// that follows looks complete while being three-quarters short.
    public func objectSize(_ handle: UInt32, path: RemotePath? = nil) async throws -> Int64? {
        guard supports(.getObjectPropValue) else { return nil }
        let result = try await transact(.getObjectPropValue,
                                        parameters: [handle, UInt32(MTPObjectProperty.objectSize)],
                                        path: path)
        var reader = MTPReader(result.data)
        guard let value = try? reader.uint64("ObjectSize") else { return nil }
        return Int64(clamping: value)
    }

    /// Streams a whole object off the device.
    public func readObject(
        handle: UInt32,
        path: RemotePath? = nil,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        try await transact(.getObject, parameters: [handle], path: path, onDataIn: onChunk)
    }

    /// Streams a byte range, where the device supports one.
    ///
    /// `GetPartialObject` takes 32-bit offsets, so past four gigabytes only the
    /// vendor-extension 64-bit form will do. A device that publishes neither
    /// cannot resume, which is what `TransportCapabilities` already says.
    public func readPartialObject(
        handle: UInt32,
        offset: Int64,
        length: Int64,
        path: RemotePath? = nil,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        if supports(.getPartialObject64) {
            let parameters: [UInt32] = [
                handle,
                UInt32(truncatingIfNeeded: offset),
                UInt32(truncatingIfNeeded: offset >> 32),
                UInt32(clamping: length)
            ]
            try await transact(.getPartialObject64, parameters: parameters, path: path, onDataIn: onChunk)
        } else if supports(.getPartialObject), offset <= Int64(UInt32.max) {
            try await transact(.getPartialObject,
                               parameters: [handle, UInt32(offset), UInt32(clamping: length)],
                               path: path, onDataIn: onChunk)
        } else {
            throw TransferError.unsupported(operation: "Resuming a copy", transport: .mtp)
        }
    }

    /// Announces an object, then streams its bytes.
    ///
    /// The two are one indivisible pair: a `SendObjectInfo` that is not followed
    /// by `SendObject` leaves a zero-byte placeholder on the phone under the
    /// real filename, which is exactly the half-written file the app promises
    /// never to leave behind. The caller gets the new handle only once both
    /// halves have completed.
    @discardableResult
    public func sendObject(
        info: MTPObjectInfo,
        from url: URL,
        size: Int64,
        path: RemotePath? = nil,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> UInt32 {
        let announced = try await transact(
            .sendObjectInfo,
            parameters: [info.storageID, info.parentHandle],
            path: path,
            dataOut: info.encoded()
        )
        // The device answers with the storage, parent, and handle it actually
        // used, which is not always the one that was asked for: a phone is free
        // to place the object elsewhere and say so.
        guard announced.parameters.count >= 3 else {
            throw TransferError.protocolError(
                "SendObjectInfo did not say where it put \(info.filename)")
        }
        let handle = announced.parameters[2]

        let transaction = nextTransactionID
        nextTransactionID &+= 1
        try await pipe.write(MTPPacket.command(.sendObject, transactionID: transaction, parameters: []))
        try await pipe.write(MTPPacket.dataHeader(.sendObject, transactionID: transaction,
                                                  payloadLength: size))

        let handleForReading = try FileHandle(forReadingFrom: url)
        defer { try? handleForReading.close() }

        var sent: Int64 = 0
        while sent < size {
            try Task.checkCancellation()
            let want = Int(min(Int64(options.writeChunkSize), size - sent))
            guard let chunk = try handleForReading.read(upToCount: want), !chunk.isEmpty else { break }
            try await pipe.write(chunk)
            sent += Int64(chunk.count)
            progress(sent)
        }
        guard sent == size else {
            throw TransferError.truncated(path: url.lastPathComponent, expected: size, actual: sent)
        }

        try await awaitResponse(for: .sendObject, path: path)
        return handle
    }

    /// Drains containers until the response to `operation` arrives.
    private func awaitResponse(for operation: MTPOperation, path: RemotePath?) async throws {
        while true {
            let container = try await readContainer(operation: operation, path: path, sink: nil)
            switch container.header.type {
            case .response:
                let raw = container.header.code
                guard let code = MTPResponseCode(rawValue: raw) else {
                    throw TransferError.protocolError(
                        "\(operation.name) answered with \(MTPResponse.describe(raw: raw))")
                }
                if let error = MTPResponse.error(for: code, operation: operation,
                                                 path: path, device: deviceID) {
                    throw error
                }
                return
            case .event:
                continue
            case .data, .command:
                throw TransferError.protocolError(
                    "the phone sent a \(container.header.type) container where \(operation.name) expected a response")
            }
        }
    }

    public func deleteObject(_ handle: UInt32, path: RemotePath? = nil) async throws {
        // The second parameter is a format filter; zero deletes the object
        // whatever it is, and on a folder Android takes the contents with it.
        try await transact(.deleteObject, parameters: [handle, 0], path: path)
    }

    public func createFolder(named name: String, parent: UInt32, storage: UInt32,
                             path: RemotePath? = nil) async throws -> UInt32 {
        let info = MTPObjectInfo(
            storageID: storage,
            objectFormat: MTPObjectFormat.association,
            size: 0,
            parentHandle: parent,
            associationType: MTPAssociation.genericFolder,
            filename: name
        )
        let result = try await transact(.sendObjectInfo, parameters: [storage, parent],
                                        path: path, dataOut: info.encoded())
        guard result.parameters.count >= 3 else {
            throw TransferError.protocolError("the phone did not say what handle it gave \(name)")
        }
        // A folder has no data phase: SendObjectInfo alone creates it, which is
        // the one case where an unaccompanied SendObjectInfo is correct.
        return result.parameters[2]
    }

    public func moveObject(_ handle: UInt32, toParent parent: UInt32, storage: UInt32,
                           path: RemotePath? = nil) async throws {
        guard supports(.moveObject) else {
            throw TransferError.unsupported(operation: "Moving a file on the device", transport: .mtp)
        }
        try await transact(.moveObject, parameters: [handle, storage, parent], path: path)
    }

    public func renameObject(_ handle: UInt32, to name: String, path: RemotePath? = nil) async throws {
        guard supports(.setObjectPropValue) else {
            throw TransferError.unsupported(operation: "Renaming a file on the device", transport: .mtp)
        }
        var writer = MTPWriter()
        writer.string(name)
        try await transact(.setObjectPropValue,
                           parameters: [handle, UInt32(MTPObjectProperty.objectFileName)],
                           path: path, dataOut: writer.data)
    }

    public func setModified(_ date: Date, handle: UInt32, path: RemotePath? = nil) async throws {
        guard supports(.setObjectPropValue) else {
            throw TransferError.unsupported(operation: "Setting a modification date", transport: .mtp)
        }
        var writer = MTPWriter()
        writer.string(MTPDate.format(date, deviceTimeZone: options.deviceTimeZone))
        try await transact(.setObjectPropValue,
                           parameters: [handle, UInt32(MTPObjectProperty.dateModified)],
                           path: path, dataOut: writer.data)
    }
}

public extension MTPSession {
    /// Every child of `parent`, with sizes and dates, in one transaction.
    ///
    /// Returns nil when the device cannot answer this way, which is a normal
    /// outcome rather than an error: the caller then walks the handles one at a
    /// time. It is only ever attempted on a real folder handle, never on the
    /// store root, because `GetObjectPropList` reads the root sentinel as
    /// "every object on the device" rather than "the top level", and on a full
    /// phone that is a hundred thousand objects in one reply.
    func children(ofParent parent: UInt32, storage: UInt32,
                  path: RemotePath? = nil) async throws -> [MTPObject]? {
        guard parent != MTPHandle.root, parent != MTPHandle.any else { return nil }
        guard supports(.getObjectPropList) else { return nil }

        let allProperties: UInt32 = 0xFFFF_FFFF
        let immediateChildren: UInt32 = 1
        let result: TransactionResult
        do {
            result = try await transact(
                .getObjectPropList,
                parameters: [parent, 0, allProperties, 0, immediateChildren],
                path: path
            )
        } catch let error as TransferError {
            // A device that lists the operation but refuses this shape of it is
            // common enough that it must degrade to the slow path, not fail the
            // folder.
            switch error {
            case .unsupported, .protocolError: return nil
            default: throw error
            }
        }

        guard let table = try? MTPObjectPropList.decode(result.data), !table.isEmpty else {
            return nil
        }

        var objects: [MTPObject] = []
        objects.reserveCapacity(table.count)
        for (handle, properties) in table {
            // The reply carries the folder that was asked about as well as its
            // children. Android adds the requested object to the list first and
            // only then walks down a level, so at depth 1 the parent is always
            // row one. Left in, it shows up in the browser as a child of
            // itself: entering it re-lists the same folder, and every click
            // adds another copy to the breadcrumb without ever going anywhere.
            guard handle != parent else { continue }

            let name = properties[MTPObjectProperty.objectFileName]?.string
                ?? properties[MTPObjectProperty.name]?.string
            // Without a name there is no path to put it at, so it is not
            // something the browser can show.
            guard let name, !name.isEmpty else { continue }
            let format = properties[MTPObjectProperty.objectFormat]?.int64
                .map { UInt16(clamping: $0) } ?? MTPObjectFormat.undefined
            let modified = properties[MTPObjectProperty.dateModified]?.string
                .flatMap { MTPDate.parse($0, deviceTimeZone: options.deviceTimeZone) }

            objects.append(MTPObject(
                handle: handle,
                parentHandle: properties[MTPObjectProperty.parentObject]?.int64
                    .map { UInt32(clamping: $0) } ?? parent,
                storageID: properties[MTPObjectProperty.storageID]?.int64
                    .map { UInt32(clamping: $0) } ?? storage,
                name: name,
                size: properties[MTPObjectProperty.objectSize]?.int64 ?? 0,
                modified: modified,
                isFolder: format == MTPObjectFormat.association
            ))
        }
        // The table is a dictionary, so the order out of it is arbitrary; the
        // browser sorts anyway, but a stable order keeps listings comparable
        // between runs and keeps tests honest.
        return objects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
