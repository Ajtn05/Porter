import Foundation

public struct DeviceID: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// The channel a device is reached over. Surfaced in the UI only as a badge.
public enum TransportKind: String, Sendable, Codable, CaseIterable, Comparable {
    case adb
    case mtp

    /// Prefer ADB when both USB modes are available.
    public var preferenceRank: Int {
        switch self {
        case .adb: return 0
        case .mtp: return 1
        }
    }

    public static func < (lhs: TransportKind, rhs: TransportKind) -> Bool {
        lhs.preferenceRank < rhs.preferenceRank
    }

    public var displayName: String {
        switch self {
        case .adb: return "USB (debugging)"
        case .mtp: return "USB (file transfer)"
        }
    }
}

/// What a device is currently able to do.
///
/// The cases are kept distinct so the UI can name the specific blocker rather
/// than showing an empty file list.
public enum DeviceReadiness: Sendable, Codable, Hashable {
    /// Browsable and writable.
    case ready
    /// Present on the USB bus but exposing no storage interface. Almost always
    /// "USB mode: charging only" on the phone.
    case chargingOnly
    /// Visible to ADB, but the RSA fingerprint has not been accepted on the phone.
    case unauthorized
    /// Enumerated over MTP, but the screen is locked, so transfers will stall.
    case locked
    /// Previously seen, but not currently reachable.
    case offline

    public var isBrowsable: Bool { self == .ready }
}

/// USB identity, straight off the bus. Present for wired devices only.
public struct USBDescriptor: Hashable, Sendable, Codable {
    public var vendorID: Int
    public var productID: Int
    public var vendorName: String?
    public var productName: String?
    public var serialNumber: String?
    public var locationID: Int
    /// The interfaces the device currently publishes. Distinguishes charge-only
    /// from file transfer.
    public var interfaces: [USBInterface]

    public init(vendorID: Int, productID: Int, vendorName: String? = nil, productName: String? = nil,
                serialNumber: String? = nil, locationID: Int = 0, interfaces: [USBInterface] = []) {
        self.vendorID = vendorID
        self.productID = productID
        self.vendorName = vendorName
        self.productName = productName
        self.serialNumber = serialNumber
        self.locationID = locationID
        self.interfaces = interfaces
    }
}

public struct USBInterface: Hashable, Sendable, Codable {
    public var interfaceClass: Int
    public var interfaceSubclass: Int
    public var interfaceProtocol: Int
    public var name: String?

    public init(interfaceClass: Int, interfaceSubclass: Int, interfaceProtocol: Int, name: String? = nil) {
        self.interfaceClass = interfaceClass
        self.interfaceSubclass = interfaceSubclass
        self.interfaceProtocol = interfaceProtocol
        self.name = name
    }

    /// USB Still Image class. Android publishes MTP under this class with the
    /// PIMA 15740 subclass/protocol pair.
    public var isMTP: Bool {
        interfaceClass == 6 && interfaceSubclass == 1 && interfaceProtocol == 1
    }

    /// Google's ADB interface is vendor-specific with this well-known
    /// subclass/protocol pair, used by every AOSP-derived device.
    public var isADB: Bool {
        interfaceClass == 255 && interfaceSubclass == 66 && interfaceProtocol == 1
    }

    /// False when the device publishes only the mandatory control interface or
    /// unusable vendor interfaces, which is the charge-only case.
    public var isStorageCapable: Bool { isMTP || isADB }
}

public struct Device: Identifiable, Hashable, Sendable, Codable {
    public var id: DeviceID
    public var displayName: String
    public var manufacturer: String?
    public var model: String?
    public var androidRelease: String?
    public var serial: String?
    public var transport: TransportKind
    public var readiness: DeviceReadiness
    public var usb: USBDescriptor?
    public var lastSeen: Date

    public init(id: DeviceID, displayName: String, manufacturer: String? = nil, model: String? = nil,
                androidRelease: String? = nil, serial: String? = nil, transport: TransportKind,
                readiness: DeviceReadiness = .ready, usb: USBDescriptor? = nil,
                lastSeen: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.manufacturer = manufacturer
        self.model = model
        self.androidRelease = androidRelease
        self.serial = serial
        self.transport = transport
        self.readiness = readiness
        self.usb = usb
        self.lastSeen = lastSeen
    }
}
