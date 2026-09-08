import Foundation

public struct DeviceID: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// Which pipe we are talking to a device over. The user picks a device; this is
/// an implementation detail we surface only as a badge.
public enum TransportKind: String, Sendable, Codable, CaseIterable, Comparable {
    case adb
    case mtp
    case wifi

    /// Preference order when the same physical device is reachable more than one
    /// way. ADB is both fastest and the only transport that reports honest sizes.
    public var preferenceRank: Int {
        switch self {
        case .adb: return 0
        case .wifi: return 1
        case .mtp: return 2
        }
    }

    public static func < (lhs: TransportKind, rhs: TransportKind) -> Bool {
        lhs.preferenceRank < rhs.preferenceRank
    }

    public var displayName: String {
        switch self {
        case .adb: return "USB (debugging)"
        case .mtp: return "USB (file transfer)"
        case .wifi: return "Wi-Fi"
        }
    }
}

/// What the device is currently able to do for us.
///
/// These map one-to-one onto the support questions in the spec: the point of
/// having distinct cases is that the UI can say exactly what is wrong instead of
/// showing an empty file list.
public enum DeviceReadiness: Sendable, Codable, Hashable {
    /// Browsable and writable.
    case ready
    /// Present on the USB bus, but exposing no storage interface. Almost always
    /// "USB mode: charging only" on the phone.
    case chargingOnly
    /// ADB sees it but the RSA fingerprint has not been accepted on the phone.
    case unauthorized
    /// MTP enumerated the device but the screen is locked, so it will stall on
    /// any real transfer.
    case locked
    /// Known to us but not currently reachable.
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
    /// The interfaces the device is currently publishing. This is what tells us
    /// "charging only" apart from "file transfer".
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

    /// The "charging only" giveaway: the phone publishes nothing but the
    /// mandatory control interface, or only vendor interfaces we can't use.
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
    /// For Wi-Fi devices, the resolved host we reached them on.
    public var endpointHost: String?
    public var lastSeen: Date

    public init(id: DeviceID, displayName: String, manufacturer: String? = nil, model: String? = nil,
                androidRelease: String? = nil, serial: String? = nil, transport: TransportKind,
                readiness: DeviceReadiness = .ready, usb: USBDescriptor? = nil,
                endpointHost: String? = nil, lastSeen: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.manufacturer = manufacturer
        self.model = model
        self.androidRelease = androidRelease
        self.serial = serial
        self.transport = transport
        self.readiness = readiness
        self.usb = usb
        self.endpointHost = endpointHost
        self.lastSeen = lastSeen
    }
}
