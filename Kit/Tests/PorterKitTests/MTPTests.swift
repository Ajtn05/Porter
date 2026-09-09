import Foundation
import Testing
@testable import PorterKit

// MARK: - Wire format

@Suite("MTP wire format")
struct MTPWireFormatTests {

    @Test("A string survives the round trip, surrogate pairs included")
    func stringRoundTrip() throws {
        var writer = MTPWriter()
        writer.string("Résumé 🎬.mp4")
        var reader = MTPReader(writer.data)
        let decoded = try reader.string()
        #expect(decoded == "Résumé 🎬.mp4")
        // One length byte, then one code unit per UTF-16 unit plus the NUL. The
        // emoji is two of those units, which is what the length has to count:
        // twelve characters, thirteen units.
        #expect("Résumé 🎬.mp4".count == 12)
        #expect(writer.count == 1 + (13 + 1) * 2)
    }

    @Test("An empty string is one byte, and does not shift the field after it")
    func emptyStringIsOneByte() throws {
        var writer = MTPWriter()
        writer.string("")
        writer.uint32(0xDEAD_BEEF)
        #expect(writer.bytes.first == 0)

        var reader = MTPReader(writer.data)
        let text = try reader.string("StorageInfo.StorageDescription")
        let following = try reader.uint32()
        #expect(text.isEmpty)
        // Writing a NUL for an empty string would put this field two bytes late,
        // which is how an unnamed volume ends up with a nonsense capacity.
        #expect(following == 0xDEAD_BEEF)
    }

    @Test("A name too long for the one-byte length is cut on a character boundary")
    func overlongNameTruncates() throws {
        var writer = MTPWriter()
        writer.string(String(repeating: "🎬", count: 200))
        var reader = MTPReader(writer.data)
        let decoded = try reader.string()
        #expect(decoded.utf16.count <= 254)
        // Half a surrogate pair decodes as a replacement character and is a
        // name Android rejects outright, so every character surviving intact is
        // the assertion that matters.
        #expect(decoded.allSatisfy { $0 == "🎬" })
        #expect(decoded.count == 127)
    }

    @Test("A short read says which field it ran out on")
    func shortReadNamesTheField() {
        do {
            var reader = MTPReader(Data([0x01, 0x02]))
            _ = try reader.uint32("StorageInfo.MaxCapacity")
            Issue.record("a four-byte read of two bytes should not succeed")
        } catch {
            #expect("\(error)".contains("StorageInfo.MaxCapacity"))
        }
    }

    @Test("An array count is checked against the bytes that are actually there")
    func corruptArrayCountIsRefused() {
        var writer = MTPWriter()
        writer.uint32(1_000_000)
        writer.uint16(1)
        let bytes = writer.data
        #expect(throws: TransferError.self) {
            var reader = MTPReader(bytes)
            _ = try reader.uint16Array("DeviceInfo.OperationsSupported")
        }
    }

    @Test("Dates parse with a zone, without one, and with an offset")
    func dateParsing() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        let local = try #require(MTPDate.parse("20260831T173929", deviceTimeZone: utc))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: local)
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 31)
        #expect(parts.hour == 17)
        #expect(parts.minute == 39)
        #expect(parts.second == 29)

        // A `Z` is absolute and must win over whatever the caller guessed.
        let plusFive = TimeZone(secondsFromGMT: 5 * 3600)!
        #expect(MTPDate.parse("20260831T173929Z", deviceTimeZone: plusFive) == local)

        // Tenths of a second are optional, and an explicit offset is honoured.
        #expect(MTPDate.parse("20260831T173929.0+0200", deviceTimeZone: utc)
                == MTPDate.parse("20260831T153929", deviceTimeZone: utc))

        #expect(MTPDate.parse("not a date") == nil)
        #expect(MTPDate.format(local, deviceTimeZone: utc) == "20260831T173929")
    }

    @Test("A command container is a header and its parameters, five at most")
    func commandFraming() throws {
        let packet = MTPPacket.command(.getObjectHandles, transactionID: 7,
                                       parameters: [65537, 0, MTPHandle.root])
        #expect(packet.count == MTPContainerHeader.byteCount + 12)

        let header = try MTPContainerHeader.decode(packet)
        #expect(header.type == .command)
        #expect(header.code == MTPOperation.getObjectHandles.rawValue)
        #expect(header.transactionID == 7)
        #expect(header.payloadLength == 12)

        // Six parameters is not a thing the protocol has.
        let capped = MTPPacket.command(.getObject, transactionID: 1, parameters: [1, 2, 3, 4, 5, 6, 7])
        #expect(capped.count == MTPContainerHeader.byteCount + 20)
    }

    @Test("A container type outside the four is refused rather than guessed at")
    func unknownContainerType() {
        var writer = MTPWriter()
        writer.uint32(12)
        writer.uint16(9)
        writer.uint16(0x1001)
        writer.uint32(0)
        let bytes = writer.data
        #expect(throws: TransferError.self) { _ = try MTPContainerHeader.decode(bytes) }
    }

    @Test("A payload too large for the 32-bit length field is sent undeclared")
    func largePayloadsDeclareNoLength() throws {
        let small = try MTPContainerHeader.decode(
            MTPPacket.dataHeader(.sendObject, transactionID: 2, payloadLength: 1024))
        #expect(small.payloadLength == 1024)

        // A 5 GB push cannot state its own length, so it states none and lets
        // the short packet end it.
        let huge = try MTPContainerHeader.decode(
            MTPPacket.dataHeader(.sendObject, transactionID: 2, payloadLength: 5_000_000_000))
        #expect(huge.payloadLength == nil)
    }

    @Test("ObjectInfo survives the round trip, and admits when a size will not fit")
    func objectInfoRoundTrip() throws {
        let info = MTPObjectInfo(
            storageID: 65537, objectFormat: MTPObjectFormat.undefined, size: 5_242_880,
            parentHandle: 12, filename: "20260831_173929.mp4", dateModified: "20260831T173929")
        #expect(try MTPObjectInfo.decode(info.encoded()) == info)

        let huge = MTPObjectInfo(
            storageID: 65537, objectFormat: MTPObjectFormat.undefined, size: 6_000_000_000,
            parentHandle: 12, filename: "big.mp4")
        // Not zero, and not the size modulo 4 GiB: nil, so the caller knows to
        // go and ask for the 64-bit property instead.
        #expect(try MTPObjectInfo.decode(huge.encoded()).size == nil)

        let folder = MTPObjectInfo(
            storageID: 65537, objectFormat: MTPObjectFormat.association, size: 0,
            parentHandle: MTPHandle.root, associationType: MTPAssociation.genericFolder,
            filename: "DCIM")
        #expect(try MTPObjectInfo.decode(folder.encoded()).isFolder)
    }

    @Test("StorageInfo reads capacity, free space, and whether the volume comes out")
    func storageInfoDecoding() throws {
        let internalStorage = try MTPStorageInfo.decode(
            MTPWire.storageInfo(description: "Internal storage",
                                capacity: 111_760_000_000, free: 2_360_000_000))
        #expect(internalStorage.description == "Internal storage")
        #expect(internalStorage.maxCapacity == 111_760_000_000)
        #expect(internalStorage.freeSpaceInBytes == 2_360_000_000)
        #expect(!internalStorage.isRemovable)

        let card = try MTPStorageInfo.decode(
            MTPWire.storageInfo(storageType: 0x0004, description: "SD card",
                                capacity: 64_000_000_000, free: 1_000))
        #expect(card.isRemovable)
    }

    @Test("DeviceInfo yields the model and the operations the phone will honour")
    func deviceInfoDecoding() throws {
        let info = try MTPDeviceInfo.decode(
            MTPWire.deviceInfo(operations: [.getObject, .getObjectPropList]))
        #expect(info.manufacturer == "Samsung")
        #expect(info.model == "SM-S901E")
        #expect(info.serialNumber == "R5CT502XWRL")
        #expect(info.supports(.getObjectPropList))
        #expect(!info.supports(.moveObject))
    }

    @Test("An ObjectPropList skips properties it has no use for without losing its place")
    func objectPropListDecoding() throws {
        var writer = MTPWriter()
        writer.uint32(4)

        writer.uint32(21)
        writer.uint16(MTPObjectProperty.objectFileName)
        writer.uint16(0xFFFF)
        writer.string("IMG_0001.JPG")

        writer.uint32(21)
        writer.uint16(MTPObjectProperty.objectSize)
        writer.uint16(0x0008)
        writer.uint64(4_294_967_296)

        // An array property this app does not read. Skipping it at the wrong
        // width would not corrupt one value, it would shift every element after
        // it, which is what the next assertion is really checking.
        writer.uint32(21)
        writer.uint16(0xDC41)
        writer.uint16(0x4006)
        writer.uint32(3)
        writer.uint32(1); writer.uint32(2); writer.uint32(3)

        writer.uint32(22)
        writer.uint16(MTPObjectProperty.objectFormat)
        writer.uint16(0x0004)
        writer.uint16(MTPObjectFormat.association)

        let table = try MTPObjectPropList.decode(writer.data)
        #expect(table[21]?[MTPObjectProperty.objectFileName]?.string == "IMG_0001.JPG")
        #expect(table[21]?[MTPObjectProperty.objectSize]?.int64 == 4_294_967_296)
        #expect(table[22]?[MTPObjectProperty.objectFormat]?.int64 == Int64(MTPObjectFormat.association))
    }

    @Test("A data type of unknown width fails the list rather than misreading it")
    func objectPropListUnknownType() {
        var writer = MTPWriter()
        writer.uint32(1)
        writer.uint32(21)
        writer.uint16(MTPObjectProperty.objectFileName)
        writer.uint16(0x1234)
        let bytes = writer.data
        #expect(throws: TransferError.self) { _ = try MTPObjectPropList.decode(bytes) }
    }
}

// MARK: - Session

/// Progress arrives on a `@Sendable` closure, so the count needs somewhere safe
/// to live.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var highWater: Int64 = 0
    func record(_ value: Int64) { lock.lock(); highWater = max(highWater, value); lock.unlock() }
    var latest: Int64 { lock.lock(); defer { lock.unlock() }; return highWater }
}

@Suite("MTP session")
struct MTPSessionTests {

    private func openedSession(_ extraReads: [Data],
                               operations: [MTPOperation] = [.getObjectPropList, .setObjectPropValue,
                                                             .moveObject, .getObjectPropValue],
                               options: MTPSession.Options = MTPSession.Options())
    async throws -> (MTPSession, FakeMTPPipe) {
        let pipe = FakeMTPPipe(reads: MTPWire.openHandshake(operations: operations) + extraReads)
        let session = MTPSession(pipe: pipe, deviceID: "phone", options: options)
        try await session.open()
        return (session, pipe)
    }

    @Test("Opening reads the device's identity, then asks for a session")
    func openHandshake() async throws {
        let (session, pipe) = try await openedSession([])

        let info = await session.deviceInfo
        #expect(info?.model == "SM-S901E")
        #expect(await session.supports(.getObjectPropList))
        #expect(await session.supports(.getPartialObject64) == false)

        let written = await pipe.written
        #expect(written.count == 2)
        #expect(try MTPContainerHeader.decode(written[0]).code == MTPOperation.getDeviceInfo.rawValue)
        #expect(try MTPContainerHeader.decode(written[1]).code == MTPOperation.openSession.rawValue)
    }

    /// Builds one GetObjectPropList row pair: a name and a format for `handle`.
    private func propListRows(_ writer: inout MTPWriter, handle: UInt32,
                              name: String, isFolder: Bool) {
        writer.uint32(handle)
        writer.uint16(MTPObjectProperty.objectFileName)
        writer.uint16(0xFFFF)
        writer.string(name)

        writer.uint32(handle)
        writer.uint16(MTPObjectProperty.objectFormat)
        writer.uint16(0x0004)
        writer.uint16(isFolder ? MTPObjectFormat.association : MTPObjectFormat.undefined)
    }

    @Test("Regression: two transactions at once do not read each other's replies")
    func concurrentTransactionsAreSerialised() async throws {
        // An actor gives up its isolation at every suspension, so without a
        // gate of its own a second exchange can begin between two packets of
        // the first. On a phone that is one command answered with another's
        // reply; here it is one of the two calls decoding an empty payload.
        //
        // Browsing is where it bites: the transfer engine is held to one stream
        // at a time, but a second folder clicked before the first has finished
        // listing is two transactions on one pipe.
        let (session, _) = try await openedSession([
            MTPWire.data(.getStorageIDs, transaction: 1, payload: MTPWire.uint32Array([65537])),
            MTPWire.response(.ok, transaction: 1),
            MTPWire.data(.getStorageIDs, transaction: 2, payload: MTPWire.uint32Array([65538])),
            MTPWire.response(.ok, transaction: 2)
        ])

        async let first = session.storageIDs()
        async let second = session.storageIDs()
        let results = try await [first, second].sorted { ($0.first ?? 0) < ($1.first ?? 0) }

        // Whichever ran first, each got a whole reply and neither got an empty
        // one.
        #expect(results == [[65537], [65538]])
    }

    @Test("Regression: a folder is not listed as a child of itself")
    func propertyListDropsTheParentRow() async throws {
        // GetObjectPropList at depth 1 answers with the folder that was asked
        // about as well as its children, because Android adds the requested
        // object before it walks down a level. Kept, it reaches the browser as
        // a child of itself: entering it re-lists the same folder, and every
        // click stacks another copy on the breadcrumb without going anywhere.
        var writer = MTPWriter()
        writer.uint32(4)
        propListRows(&writer, handle: 100, name: "Alarms", isFolder: true)
        propListRows(&writer, handle: 101, name: "alarm.ogg", isFolder: false)

        let (session, _) = try await openedSession([
            MTPWire.data(.getObjectPropList, transaction: 1, payload: writer.data),
            MTPWire.response(.ok, transaction: 1)
        ])

        let children = try await session.children(ofParent: 100, storage: 65537)
        #expect(children?.map(\.name) == ["alarm.ogg"])
    }

    @Test("Regression: an empty folder lists as empty, not as holding itself")
    func emptyFolderDoesNotListItself() async throws {
        var writer = MTPWriter()
        writer.uint32(2)
        propListRows(&writer, handle: 100, name: "Alarms", isFolder: true)

        let (session, _) = try await openedSession([
            MTPWire.data(.getObjectPropList, transaction: 1, payload: writer.data),
            MTPWire.response(.ok, transaction: 1)
        ])

        // Empty rather than nil: the phone answered, and it said there is
        // nothing in there. Nil would send the caller down the slow path to be
        // told the same thing a second time.
        #expect(try await session.children(ofParent: 100, storage: 65537)?.isEmpty == true)
    }

    @Test("A data phase split across several bulk reads is reassembled")
    func splitDataPhase() async throws {
        let payload = MTPWire.uint32Array([65537, 65538])
        let whole = MTPWire.data(.getStorageIDs, transaction: 1, payload: payload)
        let pieces = [
            Data(whole.prefix(16)),
            Data(whole.dropFirst(16).prefix(4)),
            Data(whole.dropFirst(20))
        ]
        let (session, _) = try await openedSession(pieces + [MTPWire.response(.ok, transaction: 1)])
        #expect(try await session.storageIDs() == [65537, 65538])
    }

    @Test("A response packed into the same read as the data is not lost")
    func responseSharesAReadWithTheData() async throws {
        // A payload landing on a packet boundary has no short packet to end it,
        // so the response can arrive in the same transfer. Reading that as a
        // corrupt response is the classic MTP framing bug.
        let combined = MTPWire.data(.getStorageIDs, transaction: 1,
                                    payload: MTPWire.uint32Array([65537]))
            + MTPWire.response(.ok, transaction: 1)
        let (session, _) = try await openedSession([combined])
        #expect(try await session.storageIDs() == [65537])
    }

    @Test("A zero-length packet before the response is stepped over")
    func zeroLengthPacketIsSkipped() async throws {
        let (session, _) = try await openedSession([Data(), MTPWire.response(.ok, transaction: 1)])
        try await session.deleteObject(42)
    }

    @Test("An endpoint that only returns empty packets gives up instead of hanging")
    func wedgedEndpointGivesUp() async throws {
        let (session, _) = try await openedSession([])
        await #expect(throws: TransferError.self) { _ = try await session.storageIDs() }
    }

    @Test("Access denied becomes the error about permission, not a protocol error")
    func accessDeniedMapping() async throws {
        let path = RemotePath("/65537/Android/data")
        let (session, _) = try await openedSession([MTPWire.response(.accessDenied, transaction: 1)])
        await #expect(throws: TransferError.permissionDenied(path)) {
            _ = try await session.objectInfo(42, path: path)
        }
    }

    @Test("A busy device is reported as a locked phone, which is what it is")
    func deviceBusyMeansLocked() async throws {
        // Android answers DeviceBusy for nearly everything while the screen is
        // locked, and "the phone is busy" sends nobody to the right fix.
        let (session, _) = try await openedSession([MTPWire.response(.deviceBusy, transaction: 1)])
        await #expect(throws: TransferError.deviceNotReady("phone", .locked)) {
            _ = try await session.storageIDs()
        }
    }

    @Test("An unsupported operation is named in the error")
    func unsupportedOperationMapping() async throws {
        let (session, _) = try await openedSession(
            [MTPWire.response(.operationNotSupported, transaction: 1)])
        await #expect(throws: TransferError.unsupported(operation: "MoveObject", transport: .mtp)) {
            try await session.moveObject(42, toParent: 7, storage: 65537)
        }
    }

    @Test("Sending a file announces it, streams it, and only then reports a handle")
    func sendObject() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let payload = Data((0 ..< 3000).map { UInt8($0 % 251) })
        let local = sandbox.appendingPathComponent("clip.mp4")
        try payload.write(to: local)

        let (session, pipe) = try await openedSession(
            [
                MTPWire.response(.ok, transaction: 1, parameters: [65537, 12, 2001]),
                MTPWire.response(.ok, transaction: 2)
            ],
            options: MTPSession.Options(writeChunkSize: 1024)
        )

        let info = MTPObjectInfo(storageID: 65537, objectFormat: MTPObjectFormat.undefined,
                                 size: Int64(payload.count), parentHandle: 12, filename: "clip.mp4")
        let progress = ProgressBox()
        let handle = try await session.sendObject(info: info, from: local,
                                                  size: Int64(payload.count),
                                                  progress: { progress.record($0) })

        // The handle is the device's answer, not the one that was asked for.
        #expect(handle == 2001)
        #expect(progress.latest == Int64(payload.count))

        let written = await pipe.writtenBytes
        #expect(written.suffix(payload.count) == payload)

        // Two writes to open, three for SendObjectInfo, then a command, a data
        // header, and the file in 1 KB pieces.
        let writes = await pipe.written
        let expectedWrites = 2 + 3 + 2 + 3
        #expect(writes.count == expectedWrites)
    }

    @Test("A file that runs short mid-push fails instead of reporting success")
    func truncatedPushIsRefused() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let local = sandbox.appendingPathComponent("short.bin")
        try Data(repeating: 0xAB, count: 3000).write(to: local)

        let (session, _) = try await openedSession(
            [MTPWire.response(.ok, transaction: 1, parameters: [65537, 12, 2001])])

        let info = MTPObjectInfo(storageID: 65537, objectFormat: MTPObjectFormat.undefined,
                                 size: 5000, parentHandle: 12, filename: "short.bin")
        await #expect(throws: TransferError.self) {
            // The announced size is 5000 and the file holds 3000. Letting that
            // pass would leave a file on the phone that looks whole.
            _ = try await session.sendObject(info: info, from: local, size: 5000,
                                             progress: { _ in })
        }
    }

    @Test("A whole object arrives in the chunks the bus delivered it in")
    func readObjectStreams() async throws {
        let payload = Data((0 ..< 4096).map { UInt8($0 % 256) })
        let (session, _) = try await openedSession([
            MTPWire.data(.getObject, transaction: 1, payload: payload),
            MTPWire.response(.ok, transaction: 1)
        ])

        let collected = CollectorBox()
        try await session.readObject(handle: 42) { chunk in collected.append(chunk) }
        #expect(collected.data == payload)
    }
}

/// Chunks arrive on a `@Sendable` closure and have to be gathered somewhere.
private final class CollectorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ chunk: Data) { lock.lock(); buffer.append(chunk); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}

// MARK: - Paths and handles

@Suite("MTP paths and handles")
struct MTPTransportTests {

    /// A phone with `/65537/DCIM/Camera/IMG_0001.JPG` on it.
    private func makeTransport() async -> (MTPTransport, FakeMTPBackend, Data) {
        let backend = FakeMTPBackend()
        let dcim = await backend.addFolder("DCIM")
        let camera = await backend.addFolder("Camera", parent: dcim)
        let payload = Data((0 ..< 2048).map { UInt8($0 % 256) })
        await backend.addFile("IMG_0001.JPG", parent: camera, bytes: payload)
        await backend.addFile("IMG_0002.JPG", parent: camera, bytes: Data([1, 2, 3]))
        await backend.addFolder("Download")

        let device = Device(id: "phone", displayName: "Android phone", transport: .mtp)
        return (MTPTransport(device: device, backend: backend), backend, payload)
    }

    @Test("Volumes come back with their own root path and an honest free-space flag")
    func volumes() async throws {
        let (transport, _, _) = await makeTransport()
        let volumes = try await transport.volumes()
        #expect(volumes.count == 1)
        #expect(volumes[0].id == "65537")
        #expect(volumes[0].rootPath == RemotePath("/65537"))
        #expect(volumes[0].rawName == "Internal storage")
        #expect(volumes[0].freeSpaceIsTrustworthy == false)
        // MTP cannot tell FAT32 from exFAT, so it does not claim to.
        #expect(volumes[0].filesystem == .unknown)
    }

    @Test("A phone with no stores is a locked phone, and the error says so")
    func lockedPhone() async throws {
        let (transport, backend, _) = await makeTransport()
        await backend.removeAllStorages()
        await #expect(throws: TransferError.deviceNotReady("phone", .locked)) {
            _ = try await transport.volumes()
        }
    }

    @Test("The level above the volumes lists the volumes")
    func listDeviceRoot() async throws {
        let (transport, _, _) = await makeTransport()
        let entries = try await transport.list(.root)
        #expect(entries.count == 1)
        #expect(entries[0].path == RemotePath("/65537"))
        #expect(entries[0].isDirectory)
    }

    @Test("A path is walked into handles once, then answered from the cache")
    func resolutionIsCached() async throws {
        let (transport, backend, _) = await makeTransport()
        let path = RemotePath("/65537/DCIM/Camera/IMG_0001.JPG")

        let file = try await transport.stat(path)
        #expect(file?.name == "IMG_0001.JPG")
        #expect(file?.size == 2048)

        let firstRoundTrips = await backend.handleListings + backend.propertyListCalls
        #expect(firstRoundTrips > 0)

        _ = try await transport.stat(path)
        let secondRoundTrips = await backend.handleListings + backend.propertyListCalls
        // MTP charges a round trip per level. Walking the same path twice must
        // not cost twice.
        #expect(secondRoundTrips == firstRoundTrips)
    }

    @Test("A path typed in the wrong case finds the file and reports the device's spelling")
    func caseInsensitiveResolution() async throws {
        let (transport, _, _) = await makeTransport()
        let file = try await transport.stat(RemotePath("/65537/dcim/camera/img_0001.jpg"))
        #expect(file?.path == RemotePath("/65537/DCIM/Camera/IMG_0001.JPG"))
    }

    @Test("A path that is not there is nil, not an error")
    func missingPathStatsAsNil() async throws {
        let (transport, _, _) = await makeTransport()
        #expect(try await transport.stat(RemotePath("/65537/DCIM/Nope")) == nil)
        await #expect(throws: TransferError.notFound(RemotePath("/65537/DCIM/Nope"))) {
            _ = try await transport.list(RemotePath("/65537/DCIM/Nope"))
        }
    }

    @Test("Listing a file rather than a folder says so")
    func listingAFileIsRefused() async throws {
        let (transport, _, _) = await makeTransport()
        let path = RemotePath("/65537/DCIM/Camera/IMG_0001.JPG")
        await #expect(throws: TransferError.notADirectory(path)) {
            _ = try await transport.list(path)
        }
    }

    @Test("A folder lists in one transaction when the phone can answer that way")
    func folderListingUsesOneTransaction() async throws {
        let (transport, backend, _) = await makeTransport()

        // Warms the walk down to DCIM. The store root is listed the slow way on
        // purpose: GetObjectPropList reads the root sentinel as every object on
        // the device, so the top level pays for handles one at a time and every
        // level below it does not.
        _ = try await transport.list(RemotePath("/65537/DCIM"))
        let objectInfoCallsBefore = await backend.objectInfoCalls
        #expect(objectInfoCallsBefore > 0)

        let entries = try await transport.list(RemotePath("/65537/DCIM/Camera"))
        #expect(entries.map(\.name) == ["IMG_0001.JPG", "IMG_0002.JPG"])
        // One GetObjectPropList for both files, not one GetObjectInfo each.
        #expect(await backend.objectInfoCalls == objectInfoCallsBefore)
        #expect(await backend.propertyListCalls > 0)
    }

    @Test("Without property lists it falls back, and asks for the 64-bit size when it must")
    func fallbackListingAndLargeFiles() async throws {
        let backend = FakeMTPBackend()
        let movies = await backend.addFolder("Movies")
        await backend.addFile("holiday.mp4", parent: movies, size: 6_000_000_000)
        await backend.setPropertyListSupport(false)

        let transport = MTPTransport(device: Device(id: "phone", displayName: "Phone", transport: .mtp),
                                     backend: backend)
        let entries = try await transport.list(RemotePath("/65537/Movies"))
        #expect(entries.count == 1)
        // ObjectInfo's size field tops out below this, so a wrong answer here is
        // a file that copies to 1.7 GB and still calls itself complete.
        #expect(entries[0].size == 6_000_000_000)
        #expect(await backend.objectInfoCalls > 0)
        #expect(await backend.sizeCalls > 0)
    }

    @Test("Renaming inside a folder sets the filename property rather than moving anything")
    func renameInPlace() async throws {
        let (transport, backend, _) = await makeTransport()
        // This is the engine's sidecar becoming the finished file.
        try await transport.move(from: RemotePath("/65537/DCIM/Camera/IMG_0001.JPG"),
                                 to: RemotePath("/65537/DCIM/Camera/holiday.jpg"))
        let renamed = await backend.renamed
        #expect(renamed.count == 1)
        #expect(renamed[0].name == "holiday.jpg")
        #expect(await backend.movedTo.isEmpty)
    }

    @Test("Moving between folders moves, and renames only when the name changed")
    func moveBetweenFolders() async throws {
        let (transport, backend, _) = await makeTransport()
        try await transport.move(from: RemotePath("/65537/DCIM/Camera/IMG_0001.JPG"),
                                 to: RemotePath("/65537/Download/IMG_0001.JPG"))
        #expect(await backend.movedTo.count == 1)
        #expect(await backend.renamed.isEmpty)
        let moved = try await transport.stat(RemotePath("/65537/Download/IMG_0001.JPG"))
        #expect(moved?.name == "IMG_0001.JPG")
    }

    @Test("Deleting a folder that still has files in it is refused unless asked recursively")
    func nonRecursiveDeleteOfAFullFolder() async throws {
        let (transport, backend, _) = await makeTransport()
        let camera = RemotePath("/65537/DCIM/Camera")
        await #expect(throws: TransferError.unsupported(
            operation: "Deleting a folder without its contents", transport: .mtp)) {
            try await transport.remove(camera, recursive: false)
        }
        #expect(await backend.deletedHandles.isEmpty)

        try await transport.remove(camera, recursive: true)
        #expect(await backend.deletedHandles.count == 1)
        // The cache has to let go of everything underneath, or the next stat
        // hands back a handle the phone has already forgotten.
        #expect(try await transport.stat(RemotePath("/65537/DCIM/Camera/IMG_0001.JPG")) == nil)
    }

    @Test("Creating a folder puts it under the right parent")
    func createDirectory() async throws {
        let (transport, backend, _) = await makeTransport()
        try await transport.createDirectory(RemotePath("/65537/Download/Receipts"))
        let created = await backend.createdFolders
        #expect(created.count == 1)
        #expect(created[0].name == "Receipts")
        #expect(try await transport.stat(RemotePath("/65537/Download/Receipts"))?.isDirectory == true)
    }

    @Test("Reading a file yields its bytes")
    func readStream() async throws {
        let (transport, _, payload) = await makeTransport()
        let stream = try await transport.readStream(RemotePath("/65537/DCIM/Camera/IMG_0001.JPG"))
        var received = Data()
        for try await chunk in stream { received.append(chunk) }
        #expect(received == payload)
    }

    @Test("A ranged read on a phone that cannot do one is refused, not faked")
    func rangedReadWithoutSupport() async throws {
        let (transport, _, _) = await makeTransport()
        // Silently returning the whole file for a resume would write the first
        // bytes over the middle of a partial and still pass a length check.
        await #expect(throws: TransferError.unsupported(operation: "Resuming a copy", transport: .mtp)) {
            let stream = try await transport.readStream(
                RemotePath("/65537/DCIM/Camera/IMG_0001.JPG"),
                range: ByteRange(offset: 1024))
            for try await _ in stream {}
        }
    }

    @Test("Pushing a file lands it under the right parent with the right size")
    func writeFile() async throws {
        let (transport, backend, _) = await makeTransport()
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let local = sandbox.appendingPathComponent("notes.txt")
        try Data(repeating: 0x41, count: 700).write(to: local)

        let progress = ProgressBox()
        try await transport.writeFile(from: local, to: RemotePath("/65537/Download/notes.txt"),
                                      destinationOffset: 0, progress: { progress.record($0) })

        let sent = await backend.sentObjects
        #expect(sent.count == 1)
        #expect(sent[0].name == "notes.txt")
        #expect(sent[0].size == 700)
        #expect(progress.latest == 700)
        #expect(try await transport.stat(RemotePath("/65537/Download/notes.txt"))?.size == 700)
    }

    @Test("A phone that only says \"full\" gets the numbers put back in on this side")
    func storeFullIsEnriched() async throws {
        let (transport, backend, _) = await makeTransport()
        await backend.setStoreFull(true)

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let local = sandbox.appendingPathComponent("notes.txt")
        try Data(repeating: 0x41, count: 700).write(to: local)

        // "0 bytes will not fit in the 0 bytes free" is what the device's own
        // answer would produce, and it tells nobody anything.
        await #expect(throws: TransferError.insufficientSpace(
            needed: 700, available: 2_500_000_000, volume: "Internal storage")) {
            try await transport.writeFile(from: local,
                                          to: RemotePath("/65537/Download/notes.txt"),
                                          destinationOffset: 0, progress: { _ in })
        }
    }

    @Test("A resumed push is refused rather than appended to the wrong place")
    func resumedPushIsRefused() async throws {
        let (transport, _, _) = await makeTransport()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("x.bin")
        try Data([1, 2, 3]).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        await #expect(throws: TransferError.unsupported(
            operation: "Resuming a copy onto the phone", transport: .mtp)) {
            try await transport.writeFile(from: local, to: RemotePath("/65537/Download/x.bin"),
                                          destinationOffset: 1024, progress: { _ in })
        }
    }

    @Test("The device's own identity is folded back into the sidebar entry")
    func currentDeviceIsEnriched() async throws {
        let (transport, _, _) = await makeTransport()
        let device = try await transport.currentDevice()
        #expect(device.model == "SM-S901E")
        #expect(device.serial == "R5CT502XWRL")
        #expect(device.manufacturer == "Samsung")
    }

    @Test("The transport still declares the limits the engine plans around")
    func capabilities() async throws {
        let (transport, _, _) = await makeTransport()
        let capabilities = transport.capabilities
        #expect(capabilities.maximumConcurrentStreams == 1)
        #expect(!capabilities.supportsDeviceSideChecksum)
        #expect(!capabilities.supportsRangedReads)
        #expect(!capabilities.reportsAccurateSizes)

        let hash = try await transport.checksum(RemotePath("/65537/DCIM"), algorithm: .sha256)
        #expect(hash == nil)
    }
}
