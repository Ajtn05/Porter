import Foundation

// MARK: - Containers

/// The four container types a PTP transaction is built from.
public enum MTPContainerType: UInt16, Sendable {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

/// The twelve-byte header in front of every container.
public struct MTPContainerHeader: Hashable, Sendable {
    public static let byteCount = 12

    /// What a device writes when it is streaming an object whose length it will
    /// not commit to up front. Android does this for large files, so a reader
    /// that trusts the length field will stop early on exactly the files that
    /// matter most.
    public static let undeclaredLength: UInt32 = 0xFFFF_FFFF

    public var length: UInt32
    public var type: MTPContainerType
    public var code: UInt16
    public var transactionID: UInt32

    public init(length: UInt32, type: MTPContainerType, code: UInt16, transactionID: UInt32) {
        self.length = length
        self.type = type
        self.code = code
        self.transactionID = transactionID
    }

    /// Bytes of payload after the header, or nil when the device declined to
    /// declare a length.
    public var payloadLength: Int? {
        guard length != Self.undeclaredLength else { return nil }
        return Swift.max(0, Int(length) - Self.byteCount)
    }

    public static func decode(_ data: Data) throws -> MTPContainerHeader {
        var reader = MTPReader(data)
        let length = try reader.uint32("a container length")
        let rawType = try reader.uint16("a container type")
        guard let type = MTPContainerType(rawValue: rawType) else {
            throw TransferError.protocolError(
                String(format: "container type 0x%04x is not one of the four PTP types", rawType))
        }
        let code = try reader.uint16("a container code")
        let transactionID = try reader.uint32("a transaction id")
        guard length >= UInt32(Self.byteCount) || length == Self.undeclaredLength else {
            throw TransferError.protocolError(
                "a container declared \(length) bytes, which is shorter than its own header")
        }
        return MTPContainerHeader(length: length, type: type, code: code, transactionID: transactionID)
    }

    public func encoded() -> Data {
        var writer = MTPWriter()
        writer.uint32(length)
        writer.uint16(type.rawValue)
        writer.uint16(code)
        writer.uint32(transactionID)
        return writer.data
    }
}

public enum MTPPacket {
    /// A command container: the header plus up to five 32-bit parameters.
    ///
    /// Five is the protocol's ceiling, not an arbitrary one, and a device that
    /// is sent six silently ignores the rest.
    public static func command(_ operation: MTPOperation, transactionID: UInt32,
                               parameters: [UInt32]) -> Data {
        let parameters = Array(parameters.prefix(5))
        var writer = MTPWriter()
        let length = UInt32(MTPContainerHeader.byteCount + parameters.count * 4)
        writer.raw(MTPContainerHeader(
            length: length, type: .command, code: operation.rawValue,
            transactionID: transactionID).encoded())
        for parameter in parameters { writer.uint32(parameter) }
        return writer.data
    }

    /// A data container header for a payload of `payloadLength` bytes. The
    /// payload follows on the same endpoint and is not copied through here, so a
    /// four-gigabyte push never becomes a four-gigabyte `Data`.
    ///
    /// The length field is 32 bits and has to cover the header too, so anything
    /// from `0xFFFFFFFF - 12` upwards cannot be declared at all. The protocol's
    /// answer is to declare nothing and let the short packet end the transfer,
    /// which is what every stack does for large files.
    public static func dataHeader(_ operation: MTPOperation, transactionID: UInt32,
                                  payloadLength: Int64) -> Data {
        let total = Int64(MTPContainerHeader.byteCount) + payloadLength
        let length = total < Int64(MTPContainerHeader.undeclaredLength)
            ? UInt32(total)
            : MTPContainerHeader.undeclaredLength
        return MTPContainerHeader(
            length: length, type: .data, code: operation.rawValue, transactionID: transactionID
        ).encoded()
    }
}

// MARK: - Operations

/// The operations this transport issues. Deliberately not the whole of PTP:
/// anything not listed here is not spoken, and the device's `DeviceInfo` is
/// consulted before the optional ones are used.
public enum MTPOperation: UInt16, Sendable, CaseIterable {
    case getDeviceInfo        = 0x1001
    case openSession          = 0x1002
    case closeSession         = 0x1003
    case getStorageIDs        = 0x1004
    case getStorageInfo       = 0x1005
    case getNumObjects        = 0x1006
    case getObjectHandles     = 0x1007
    case getObjectInfo        = 0x1008
    case getObject            = 0x1009
    case deleteObject         = 0x100B
    case sendObjectInfo       = 0x100C
    case sendObject           = 0x100D
    case moveObject           = 0x1019
    case copyObject           = 0x101A
    case getPartialObject     = 0x101B
    /// MTP vendor extension. 64-bit offsets, so it is the only ranged read that
    /// works past four gigabytes.
    case getPartialObject64   = 0x95C1
    case getObjectPropsSupported = 0x9801
    case getObjectPropDesc    = 0x9802
    case getObjectPropValue   = 0x9803
    case setObjectPropValue   = 0x9804
    case getObjectPropList    = 0x9805
    case truncateObject       = 0x950C
    case beginEditObject      = 0x950E
    case endEditObject        = 0x950F

    public var name: String {
        switch self {
        case .getDeviceInfo: return "GetDeviceInfo"
        case .openSession: return "OpenSession"
        case .closeSession: return "CloseSession"
        case .getStorageIDs: return "GetStorageIDs"
        case .getStorageInfo: return "GetStorageInfo"
        case .getNumObjects: return "GetNumObjects"
        case .getObjectHandles: return "GetObjectHandles"
        case .getObjectInfo: return "GetObjectInfo"
        case .getObject: return "GetObject"
        case .deleteObject: return "DeleteObject"
        case .sendObjectInfo: return "SendObjectInfo"
        case .sendObject: return "SendObject"
        case .moveObject: return "MoveObject"
        case .copyObject: return "CopyObject"
        case .getPartialObject: return "GetPartialObject"
        case .getPartialObject64: return "GetPartialObject64"
        case .getObjectPropsSupported: return "GetObjectPropsSupported"
        case .getObjectPropDesc: return "GetObjectPropDesc"
        case .getObjectPropValue: return "GetObjectPropValue"
        case .setObjectPropValue: return "SetObjectPropValue"
        case .getObjectPropList: return "GetObjectPropList"
        case .truncateObject: return "TruncateObject"
        case .beginEditObject: return "BeginEditObject"
        case .endEditObject: return "EndEditObject"
        }
    }

    /// Whether the operation's data phase travels towards the device.
    public var sendsData: Bool {
        switch self {
        case .sendObjectInfo, .sendObject, .setObjectPropValue: return true
        default: return false
        }
    }
}

/// Response codes, narrowed to the ones a phone actually returns, each mapped to
/// an error the user can act on.
public enum MTPResponseCode: UInt16, Sendable {
    case ok                        = 0x2001
    case generalError               = 0x2002
    case sessionNotOpen             = 0x2003
    case invalidTransactionID       = 0x2004
    case operationNotSupported      = 0x2005
    case parameterNotSupported      = 0x2006
    case incompleteTransfer         = 0x2007
    case invalidStorageID           = 0x2008
    case invalidObjectHandle        = 0x2009
    case devicePropNotSupported     = 0x200A
    case storeFull                  = 0x200C
    case objectWriteProtected       = 0x200D
    case storeReadOnly              = 0x200E
    case accessDenied               = 0x200F
    case partialDeletion            = 0x2012
    case storeNotAvailable          = 0x2013
    case specificationByFormatUnsupported = 0x2014
    case noValidObjectInfo          = 0x2015
    case deviceBusy                 = 0x2019
    case invalidParentObject        = 0x201A
    case invalidParameter           = 0x201D
    case sessionAlreadyOpen         = 0x201E
    case transactionCancelled       = 0x201F
    case objectTooLarge             = 0xA809
    case objectPropNotSupported     = 0xA80A

    public var isSuccess: Bool { self == .ok }
}

public enum MTPResponse {
    /// Turns a response code into the error the rest of the app already knows
    /// how to present.
    ///
    /// The point of doing this here rather than at the call site is that MTP's
    /// codes are far vaguer than the app's errors, and the translation is where
    /// the guesswork belongs. `DeviceBusy` in particular is what a locked phone
    /// returns for almost everything, which is why it maps to the readiness
    /// case that tells the user to unlock the screen rather than to a generic
    /// failure.
    public static func error(for code: MTPResponseCode, operation: MTPOperation,
                             path: RemotePath?, device: DeviceID) -> TransferError? {
        let subject = path ?? RemotePath.root
        switch code {
        case .ok:
            return nil
        case .accessDenied, .objectWriteProtected, .storeReadOnly:
            return .permissionDenied(subject)
        case .invalidObjectHandle, .noValidObjectInfo:
            return .notFound(subject)
        case .invalidParentObject:
            return .notFound(subject.parent ?? subject)
        case .invalidStorageID, .storeNotAvailable:
            return .notFound(subject)
        case .storeFull:
            return .insufficientSpace(needed: 0, available: 0, volume: subject.string)
        case .deviceBusy:
            return .deviceNotReady(device, .locked)
        case .sessionNotOpen, .invalidTransactionID:
            return .transportUnavailable(
                .mtp, reason: "the file-transfer session closed. Unplug the cable and plug it back in.")
        case .operationNotSupported, .parameterNotSupported,
             .specificationByFormatUnsupported, .objectPropNotSupported,
             .devicePropNotSupported:
            return .unsupported(operation: operation.name, transport: .mtp)
        case .objectTooLarge:
            // The store will not hold a file this size. Without a limit to
            // quote, saying so plainly beats a filesystem error with two zeroes
            // in it.
            return .unsupported(operation: "Copying a file this large to this volume",
                                transport: .mtp)
        case .incompleteTransfer, .partialDeletion:
            return .deviceDisconnected(during: operation.name)
        case .transactionCancelled:
            return .cancelled
        case .sessionAlreadyOpen:
            return nil
        case .invalidParameter, .generalError:
            return .protocolError("\(operation.name) was refused with \(describe(code))")
        }
    }

    public static func describe(_ code: MTPResponseCode) -> String {
        String(format: "%@ (0x%04x)", "\(code)", code.rawValue)
    }

    public static func describe(raw: UInt16) -> String {
        if let known = MTPResponseCode(rawValue: raw) { return describe(known) }
        return String(format: "an unknown response code (0x%04x)", raw)
    }
}

// MARK: - Datasets

/// Object formats, of which only one matters structurally: `association` is how
/// MTP says "folder".
public enum MTPObjectFormat {
    public static let undefined: UInt16 = 0x3000
    public static let association: UInt16 = 0x3001
    /// What a file of no particular type is sent as.
    public static let undefinedNonImage: UInt16 = 0x3000
}

public enum MTPAssociation {
    public static let genericFolder: UInt16 = 0x0001
}

/// Handle sentinels. `root` is the parent value that means "the top of the
/// store"; zero means "anywhere in the store" and would return every object on
/// the phone in one listing, which on a full device is a hundred thousand
/// handles and several seconds of stall.
public enum MTPHandle {
    public static let root: UInt32 = 0xFFFF_FFFF
    public static let any: UInt32 = 0x0000_0000
}

public enum MTPObjectProperty {
    public static let storageID: UInt16 = 0xDC01
    public static let objectFormat: UInt16 = 0xDC02
    public static let objectSize: UInt16 = 0xDC04
    public static let objectFileName: UInt16 = 0xDC07
    public static let dateModified: UInt16 = 0xDC09
    public static let parentObject: UInt16 = 0xDC0B
    public static let name: UInt16 = 0xDC44
}

/// The `ObjectInfo` dataset, returned by `GetObjectInfo` and sent by
/// `SendObjectInfo`.
public struct MTPObjectInfo: Hashable, Sendable {
    public var storageID: UInt32
    public var objectFormat: UInt16
    public var protectionStatus: UInt16
    /// The dataset's size field is 32 bits, so anything at or above four
    /// gigabytes cannot be expressed. Devices signal that by writing
    /// `0xFFFFFFFF`, and the real figure has to come from the 64-bit
    /// `ObjectSize` property instead. `size` is nil in exactly that case rather
    /// than being silently wrong.
    public var size: Int64?
    public var parentHandle: UInt32
    public var associationType: UInt16
    public var filename: String
    public var dateCreated: String
    public var dateModified: String

    public var isFolder: Bool { objectFormat == MTPObjectFormat.association }

    public init(storageID: UInt32, objectFormat: UInt16, protectionStatus: UInt16 = 0,
                size: Int64?, parentHandle: UInt32, associationType: UInt16 = 0,
                filename: String, dateCreated: String = "", dateModified: String = "") {
        self.storageID = storageID
        self.objectFormat = objectFormat
        self.protectionStatus = protectionStatus
        self.size = size
        self.parentHandle = parentHandle
        self.associationType = associationType
        self.filename = filename
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }

    public static func decode(_ data: Data) throws -> MTPObjectInfo {
        var reader = MTPReader(data)
        let storageID = try reader.uint32("ObjectInfo.StorageID")
        let format = try reader.uint16("ObjectInfo.ObjectFormat")
        let protection = try reader.uint16("ObjectInfo.ProtectionStatus")
        let rawSize = try reader.uint32("ObjectInfo.ObjectCompressedSize")
        // Thumbnail block: format, size, and four dimension fields, none of
        // which this app has any use for.
        try reader.skip(2 + 4 + 4 + 4, "ObjectInfo thumbnail fields")
        try reader.skip(4 + 4 + 4, "ObjectInfo image fields")
        let parent = try reader.uint32("ObjectInfo.ParentObject")
        let association = try reader.uint16("ObjectInfo.AssociationType")
        try reader.skip(4, "ObjectInfo.AssociationDesc")
        try reader.skip(4, "ObjectInfo.SequenceNumber")
        let filename = try reader.string("ObjectInfo.Filename")
        // Some stacks stop the dataset after the filename. That is legal enough
        // in practice and must not fail the listing, so the dates are optional.
        let created = (try? reader.string("ObjectInfo.DateCreated")) ?? ""
        let modified = (try? reader.string("ObjectInfo.DateModified")) ?? ""

        return MTPObjectInfo(
            storageID: storageID,
            objectFormat: format,
            protectionStatus: protection,
            size: rawSize == 0xFFFF_FFFF ? nil : Int64(rawSize),
            parentHandle: parent,
            associationType: association,
            filename: filename,
            dateCreated: created,
            dateModified: modified
        )
    }

    public func encoded() -> Data {
        var writer = MTPWriter()
        writer.uint32(storageID)
        writer.uint16(objectFormat)
        writer.uint16(protectionStatus)
        // A size at or beyond the 32-bit ceiling is announced as 0xFFFFFFFF,
        // which is what tells the device to expect the real length from the
        // data phase rather than from this field.
        if let size, size < Int64(UInt32.max) {
            writer.uint32(UInt32(size))
        } else {
            writer.uint32(0xFFFF_FFFF)
        }
        writer.uint16(0)          // ThumbFormat
        writer.uint32(0)          // ThumbCompressedSize
        writer.uint32(0)          // ThumbPixWidth
        writer.uint32(0)          // ThumbPixHeight
        writer.uint32(0)          // ImagePixWidth
        writer.uint32(0)          // ImagePixHeight
        writer.uint32(0)          // ImageBitDepth
        writer.uint32(parentHandle)
        writer.uint16(associationType)
        writer.uint32(0)          // AssociationDesc
        writer.uint32(0)          // SequenceNumber
        writer.string(filename)
        writer.string(dateCreated)
        writer.string(dateModified)
        writer.string("")         // Keywords
        return writer.data
    }
}

/// The `StorageInfo` dataset, one per volume the phone exposes.
public struct MTPStorageInfo: Hashable, Sendable {
    public var storageType: UInt16
    public var filesystemType: UInt16
    public var accessCapability: UInt16
    public var maxCapacity: Int64
    public var freeSpaceInBytes: Int64
    public var description: String
    public var volumeIdentifier: String

    /// Removable-RAM is how every SD card presents itself; fixed-RAM is
    /// internal storage.
    public var isRemovable: Bool { storageType == 0x0004 || storageType == 0x0002 }
    public var isReadOnly: Bool { accessCapability != 0x0000 }

    public static func decode(_ data: Data) throws -> MTPStorageInfo {
        var reader = MTPReader(data)
        let storageType = try reader.uint16("StorageInfo.StorageType")
        let filesystemType = try reader.uint16("StorageInfo.FilesystemType")
        let access = try reader.uint16("StorageInfo.AccessCapability")
        let capacity = try reader.uint64("StorageInfo.MaxCapacity")
        let free = try reader.uint64("StorageInfo.FreeSpaceInBytes")
        try reader.skip(4, "StorageInfo.FreeSpaceInImages")
        let description = try reader.string("StorageInfo.StorageDescription")
        let volumeIdentifier = (try? reader.string("StorageInfo.VolumeIdentifier")) ?? ""

        return MTPStorageInfo(
            storageType: storageType,
            filesystemType: filesystemType,
            accessCapability: access,
            // Clamped because the fields are unsigned 64-bit and a phone that
            // reports garbage should produce a wrong number, not a crash.
            maxCapacity: Int64(clamping: capacity),
            freeSpaceInBytes: Int64(clamping: free),
            description: description,
            volumeIdentifier: volumeIdentifier
        )
    }
}

/// The `DeviceInfo` dataset. Read once at connect, for the model name and for
/// the list of operations the device will actually honour.
public struct MTPDeviceInfo: Hashable, Sendable {
    public var standardVersion: UInt16
    public var vendorExtensionID: UInt32
    public var vendorExtensionDescription: String
    public var operationsSupported: Set<UInt16>
    public var manufacturer: String
    public var model: String
    public var deviceVersion: String
    public var serialNumber: String

    public func supports(_ operation: MTPOperation) -> Bool {
        operationsSupported.contains(operation.rawValue)
    }

    public static func decode(_ data: Data) throws -> MTPDeviceInfo {
        var reader = MTPReader(data)
        let standardVersion = try reader.uint16("DeviceInfo.StandardVersion")
        let vendorExtensionID = try reader.uint32("DeviceInfo.VendorExtensionID")
        try reader.skip(2, "DeviceInfo.VendorExtensionVersion")
        let vendorDescription = try reader.string("DeviceInfo.VendorExtensionDesc")
        try reader.skip(2, "DeviceInfo.FunctionalMode")
        let operations = try reader.uint16Array("DeviceInfo.OperationsSupported")
        _ = try reader.uint16Array("DeviceInfo.EventsSupported")
        _ = try reader.uint16Array("DeviceInfo.DevicePropertiesSupported")
        _ = try reader.uint16Array("DeviceInfo.CaptureFormats")
        _ = try reader.uint16Array("DeviceInfo.ImageFormats")
        let manufacturer = try reader.string("DeviceInfo.Manufacturer")
        let model = try reader.string("DeviceInfo.Model")
        let deviceVersion = (try? reader.string("DeviceInfo.DeviceVersion")) ?? ""
        let serial = (try? reader.string("DeviceInfo.SerialNumber")) ?? ""

        return MTPDeviceInfo(
            standardVersion: standardVersion,
            vendorExtensionID: vendorExtensionID,
            vendorExtensionDescription: vendorDescription,
            operationsSupported: Set(operations),
            manufacturer: manufacturer,
            model: model,
            deviceVersion: deviceVersion,
            serialNumber: serial
        )
    }
}

// MARK: - Object property lists

/// A property value, narrowed to the two shapes this app reads: a number of
/// some width, and a string.
public enum MTPPropertyValue: Hashable, Sendable {
    case number(UInt64)
    case text(String)

    public var int64: Int64? {
        guard case .number(let value) = self else { return nil }
        return Int64(clamping: value)
    }

    public var string: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }
}

/// The `ObjectPropList` dataset returned by `GetObjectPropList`.
///
/// This is the difference between a folder of five thousand photos listing in
/// one transaction and listing in five thousand. `GetObjectInfo` per handle is
/// correct and is what the fallback does, but on MTP a round trip costs
/// milliseconds and five thousand of them is most of a minute of staring at a
/// spinner.
public enum MTPObjectPropList {
    /// Values are keyed by object handle, then by property code.
    public static func decode(_ data: Data) throws -> [UInt32: [UInt16: MTPPropertyValue]] {
        var reader = MTPReader(data)
        let count = Int(try reader.uint32("ObjectPropList element count"))
        // The smallest possible element is a handle, a code, a type, and a
        // one-byte empty string. Checking against that before allocating stops
        // a corrupt count from asking for the whole heap.
        guard count >= 0, count * 9 <= reader.remaining + 9 else {
            throw TransferError.protocolError(
                "an ObjectPropList claims \(count) entries but carries \(reader.remaining) bytes")
        }

        var result: [UInt32: [UInt16: MTPPropertyValue]] = [:]
        for _ in 0 ..< count {
            let handle = try reader.uint32("ObjectPropList.ObjectHandle")
            let code = try reader.uint16("ObjectPropList.PropertyCode")
            let type = try reader.uint16("ObjectPropList.DataType")
            if let value = try readValue(&reader, type: type) {
                result[handle, default: [:]][code] = value
            }
        }
        return result
    }

    /// Reads one typed value, skipping the ones this app has no use for.
    ///
    /// Skipping has to be exact: a value read at the wrong width does not
    /// corrupt one property, it shifts every remaining element in the list. A
    /// type that cannot be sized is therefore an error rather than a guess, and
    /// the caller falls back to `GetObjectInfo` per handle.
    private static func readValue(_ reader: inout MTPReader, type: UInt16) throws -> MTPPropertyValue? {
        if type == 0xFFFF {
            return .text(try reader.string("an ObjectPropList string"))
        }
        if let width = scalarWidth(type) {
            switch width {
            case 1: return .number(UInt64(try reader.uint8("a property value")))
            case 2: return .number(UInt64(try reader.uint16("a property value")))
            case 4: return .number(UInt64(try reader.uint32("a property value")))
            case 8: return .number(try reader.uint64("a property value"))
            default:
                try reader.skip(width, "a wide property value")
                return nil
            }
        }
        // Array types are the scalar types with 0x4000 set, prefixed by a count.
        if type > 0x4000, let width = scalarWidth(type & 0x00FF) {
            let count = Int(try reader.uint32("a property array count"))
            guard count >= 0, count * width <= reader.remaining else {
                throw TransferError.protocolError(
                    "a property array claims \(count) entries of \(width) bytes")
            }
            try reader.skip(count * width, "a property array")
            return nil
        }
        throw TransferError.protocolError(
            String(format: "an ObjectPropList used data type 0x%04x, which has no known width", type))
    }

    private static func scalarWidth(_ type: UInt16) -> Int? {
        switch type {
        case 0x0001, 0x0002: return 1     // INT8, UINT8
        case 0x0003, 0x0004: return 2     // INT16, UINT16
        case 0x0005, 0x0006: return 4     // INT32, UINT32
        case 0x0007, 0x0008: return 8     // INT64, UINT64
        case 0x0009, 0x000A: return 16    // INT128, UINT128
        default: return nil
        }
    }
}
