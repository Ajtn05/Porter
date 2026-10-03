import Foundation
import Testing
@testable import PorterKit

@Suite("MTP browsing fast paths")
struct MTPPreviewTests {
    private func session(_ reads: [Data], operations: [MTPOperation]) async throws -> (MTPSession, FakeMTPPipe) {
        let pipe = FakeMTPPipe(reads: MTPWire.openHandshake(operations: operations) + reads)
        let session = MTPSession(pipe: pipe, deviceID: "phone")
        try await session.open()
        return (session, pipe)
    }

    private func row(_ writer: inout MTPWriter, handle: UInt32, storage: UInt32,
                     parent: UInt32, name: String, folder: Bool = false) {
        writer.uint32(handle); writer.uint16(MTPObjectProperty.storageID); writer.uint16(0x0006); writer.uint32(storage)
        writer.uint32(handle); writer.uint16(MTPObjectProperty.parentObject); writer.uint16(0x0006); writer.uint32(parent)
        writer.uint32(handle); writer.uint16(MTPObjectProperty.objectFormat); writer.uint16(0x0004)
        writer.uint16(folder ? MTPObjectFormat.association : MTPObjectFormat.undefined)
        writer.uint32(handle); writer.uint16(MTPObjectProperty.objectFileName); writer.uint16(0xFFFF); writer.string(name)
        writer.uint32(handle); writer.uint16(MTPObjectProperty.objectSize); writer.uint16(0x0008); writer.uint64(4096)
    }

    @Test("Root property query uses handle zero and filters stores and descendants")
    func rootQuery() async throws {
        var writer = MTPWriter()
        writer.uint32(20)
        row(&writer, handle: 10, storage: 65537, parent: 0, name: "DCIM", folder: true)
        row(&writer, handle: 11, storage: 65537, parent: MTPHandle.root, name: "Download", folder: true)
        row(&writer, handle: 12, storage: 65538, parent: 0, name: "Other volume", folder: true)
        row(&writer, handle: 13, storage: 65537, parent: 10, name: "nested.jpg")
        let (session, pipe) = try await session([
            MTPWire.data(.getObjectPropList, transaction: 1, payload: writer.data),
            MTPWire.response(.ok, transaction: 1)
        ], operations: [.getObjectPropList])
        let result = try await session.children(ofParent: MTPHandle.root, storage: 65537)
        #expect(result?.map(\.name) == ["DCIM", "Download"])
        let commands = await pipe.written
        var reader = MTPReader(commands.last!.dropFirst(MTPContainerHeader.byteCount))
        #expect(try reader.uint32() == 0) // Never 0xFFFFFFFF: that enumerates the whole phone.
        #expect(try reader.uint32() == 0)
        #expect(try reader.uint32() == UInt32.max)
        #expect(try reader.uint32() == 0)
        #expect(try reader.uint32() == 0) // Root needs depth zero, not a recursive walk.
    }

    @Test("Empty root property list is complete and needs no per-object fallback")
    func emptyRoot() async throws {
        let (session, _) = try await session([
            MTPWire.data(.getObjectPropList, transaction: 1, payload: MTPWire.uint32Array([])),
            MTPWire.response(.ok, transaction: 1)
        ], operations: [.getObjectPropList])
        #expect(try await session.children(ofParent: MTPHandle.root, storage: 65537) == [])
    }

    @Test("Root without storage and parent metadata falls back safely")
    func incompleteRoot() async throws {
        var writer = MTPWriter()
        writer.uint32(1)
        writer.uint32(10); writer.uint16(MTPObjectProperty.objectFileName); writer.uint16(0xFFFF); writer.string("DCIM")
        let (session, _) = try await session([
            MTPWire.data(.getObjectPropList, transaction: 1, payload: writer.data),
            MTPWire.response(.ok, transaction: 1)
        ], operations: [.getObjectPropList])
        #expect(try await session.children(ofParent: MTPHandle.root, storage: 65537) == nil)
    }

    @Test("Native thumbnail reads no original file")
    func nativeThumbnail() async throws {
        let thumbnail = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let (session, pipe) = try await session([
            MTPWire.data(.getThumb, transaction: 1, payload: thumbnail), MTPWire.response(.ok, transaction: 1)
        ], operations: [.getThumb])
        #expect(try await session.thumbnail(42) == thumbnail)
        let commands = await pipe.written
        #expect(commands.count == 3)
        #expect(try MTPContainerHeader.decode(commands.last!).code == MTPOperation.getThumb.rawValue)
    }

    @Test("Missing thumbnail preserves the following directory transaction", arguments: [MTPResponseCode.noThumbnailPresent, .generalError])
    func missingThumbnail(_ response: MTPResponseCode) async throws {
        let (session, _) = try await session([
            MTPWire.response(response, transaction: 1),
            MTPWire.data(.getStorageIDs, transaction: 2, payload: MTPWire.uint32Array([65537])),
            MTPWire.response(.ok, transaction: 2)
        ], operations: [.getThumb])
        #expect(try await session.thumbnail(42) == nil)
        #expect(try await session.storageIDs() == [65537])
    }

    @Test("An unsupported thumbnail operation is probed only once")
    func unsupportedThumbnail() async throws {
        let (session, pipe) = try await session([MTPWire.response(.operationNotSupported, transaction: 1)], operations: [.getThumb])
        #expect(try await session.thumbnail(42) == nil)
        #expect(try await session.thumbnail(43) == nil)
        #expect(await pipe.written.count == 3)
    }

    @Test("Oversized thumbnail is discarded and the response is drained")
    func oversizedThumbnail() async throws {
        let (session, _) = try await session([
            MTPWire.data(.getThumb, transaction: 1, payload: Data(repeating: 0xAB, count: 1024 * 1024 + 1)),
            MTPWire.response(.ok, transaction: 1),
            MTPWire.data(.getStorageIDs, transaction: 2, payload: MTPWire.uint32Array([65537])),
            MTPWire.response(.ok, transaction: 2)
        ], operations: [.getThumb])
        #expect(try await session.thumbnail(42) == nil)
        #expect(try await session.storageIDs() == [65537])
    }

    @Test("Cold root listing needs one batch and zero object-info requests")
    func coldRoot() async throws {
        let backend = FakeMTPBackend()
        for index in 0..<100 { await backend.addFolder("Folder \(index)") }
        let transport = MTPTransport(device: Device(id: "phone", displayName: "Phone", transport: .mtp), backend: backend)
        #expect(try await transport.list(RemotePath("/65537")).count == 100)
        #expect(await backend.propertyListCalls == 1)
        #expect(await backend.handleListings == 0)
        #expect(await backend.objectInfoCalls == 0)
    }
}
