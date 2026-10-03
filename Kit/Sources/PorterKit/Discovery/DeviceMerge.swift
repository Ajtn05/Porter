import Foundation

/// Combines the discovery sources into a single device list.
///
/// One physical phone can appear on the USB bus and in `adb devices` at once.
/// Kept pure so the USB and ADB merge can be tested directly.
public enum DeviceMerge {
    public static func merge(
        usb: [USBDeviceMonitor.Snapshot],
        adb: [ADBParsing.DeviceListing],
        now: Date = Date()
    ) -> [Device] {
        var devices: [Device] = []
        var claimedSerials: Set<String> = []

        // 1. ADB first: it is the preferred transport, so its view wins.
        for listing in adb where !listing.isNetworkAddress {
            let usbMatch = usb.first { $0.descriptor.serialNumber == listing.serial }
            let mtpAvailable = listing.readiness != .ready
                && usbMatch?.descriptor.interfaces.contains(where: \.isMTP) == true
            claimedSerials.insert(listing.serial)
            devices.append(Device(
                id: DeviceID(listing.serial),
                displayName: listing.model ?? usbMatch?.descriptor.productName ?? listing.serial,
                manufacturer: usbMatch?.manufacturerGuess,
                model: listing.model,
                serial: listing.serial,
                transport: mtpAvailable ? .mtp : .adb,
                readiness: mtpAvailable ? .ready : listing.readiness,
                usb: usbMatch?.descriptor,
                lastSeen: now
            ))
        }

        // 2. Wired devices adb cannot see: either MTP is available, or the
        //    phone is on the bus exposing no storage interface, which is the
        //    charge-only case.
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

        // Ready devices first, then by name, so the list is stable as
        // transports come and go.
        return devices.sorted { lhs, rhs in
            if lhs.readiness.isBrowsable != rhs.readiness.isBrowsable {
                return lhs.readiness.isBrowsable
            }
            if lhs.transport != rhs.transport { return lhs.transport < rhs.transport }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }
}
