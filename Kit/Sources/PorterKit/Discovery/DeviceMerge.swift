import Foundation

/// Combines what each discovery source knows into the single list the user sees.
///
/// Pure and separately testable, because the interesting behaviour lives here:
/// one physical phone can appear on the USB bus, in `adb devices`, and over
/// Bonjour all at once, and it must show up as one row with the best available
/// transport — while a phone that appears *only* on the bus has to be recognised
/// as charge-only rather than quietly dropped.
public enum DeviceMerge {

    public struct WirelessDevice: Hashable, Sendable {
        public var id: DeviceID
        public var name: String
        public var host: String
        public var model: String?
        public var serial: String?

        public init(id: DeviceID, name: String, host: String, model: String? = nil, serial: String? = nil) {
            self.id = id
            self.name = name
            self.host = host
            self.model = model
            self.serial = serial
        }
    }

    public static func merge(
        usb: [USBDeviceMonitor.Snapshot],
        adb: [ADBParsing.DeviceListing],
        wireless: [WirelessDevice] = [],
        now: Date = Date()
    ) -> [Device] {
        var devices: [Device] = []
        var claimedSerials: Set<String> = []

        // 1. ADB first: it is the best transport, so anything it can see wins.
        for listing in adb where !listing.isWireless {
            let usbMatch = usb.first { $0.descriptor.serialNumber == listing.serial }
            claimedSerials.insert(listing.serial)
            devices.append(Device(
                id: DeviceID(listing.serial),
                displayName: listing.model ?? usbMatch?.descriptor.productName ?? listing.serial,
                manufacturer: usbMatch?.manufacturerGuess,
                model: listing.model,
                serial: listing.serial,
                transport: .adb,
                readiness: listing.readiness,
                usb: usbMatch?.descriptor,
                lastSeen: now
            ))
        }

        // 2. Wired devices adb cannot see. Either MTP is available, or the phone
        //    is on the bus with no storage interface at all — which is the
        //    charge-only case, and the whole reason this list is merged rather
        //    than taken from adb alone.
        for snapshot in usb {
            let serial = snapshot.descriptor.serialNumber
            if let serial, claimedSerials.contains(serial) { continue }
            let identifier = serial ?? "usb-\(snapshot.descriptor.locationID)"
            devices.append(Device(
                id: DeviceID(identifier),
                displayName: snapshot.descriptor.productName
                    ?? snapshot.manufacturerGuess.map { "\($0) device" }
                    ?? "Android device",
                manufacturer: snapshot.manufacturerGuess,
                serial: serial,
                transport: .mtp,
                readiness: snapshot.exposesStorage ? .ready : .chargingOnly,
                usb: snapshot.descriptor,
                lastSeen: now
            ))
            if let serial { claimedSerials.insert(serial) }
        }

        // 3. Wi-Fi, but only for devices not already reachable over a cable:
        //    the user picked a phone, and we should silently use the fast pipe.
        for device in wireless {
            if let serial = device.serial, claimedSerials.contains(serial) { continue }
            devices.append(Device(
                id: device.id,
                displayName: device.name,
                model: device.model,
                serial: device.serial,
                transport: .wifi,
                readiness: .ready,
                endpointHost: device.host,
                lastSeen: now
            ))
        }

        // Ready devices first, then by name, so the list does not jump around
        // as transports come and go.
        return devices.sorted { lhs, rhs in
            if lhs.readiness.isBrowsable != rhs.readiness.isBrowsable {
                return lhs.readiness.isBrowsable
            }
            if lhs.transport != rhs.transport { return lhs.transport < rhs.transport }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }
}
