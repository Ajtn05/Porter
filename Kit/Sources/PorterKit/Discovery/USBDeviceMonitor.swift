import Foundation
import IOKit
import IOKit.usb

/// Watches the USB bus and reports Android devices, whether or not they are
/// currently sharing any files.
///
/// This is deliberately independent of both adb and MTP. It is the only layer
/// that can tell "nothing is plugged in" apart from "a phone is plugged in and
/// set to charge only", which is the single most common reason people think a
/// transfer app is broken.
public final class USBDeviceMonitor: @unchecked Sendable {

    public struct Snapshot: Hashable, Sendable {
        public var descriptor: USBDescriptor
        /// True when the phone publishes MTP or ADB. False means charge-only.
        public var exposesStorage: Bool
        public var manufacturerGuess: String?
    }

    private let queue = DispatchQueue(label: "app.porter.usb-monitor")
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var handler: (@Sendable ([Snapshot]) -> Void)?

    public init() {}

    deinit { stopUnsafely() }

    /// Begins watching. `onChange` fires immediately with the current state and
    /// then on every attach or detach.
    public func start(onChange: @escaping @Sendable ([Snapshot]) -> Void) {
        queue.async { [self] in
            handler = onChange

            guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
                // Without notifications we still deliver one snapshot rather
                // than leaving the UI permanently empty.
                onChange(Self.currentDevices())
                return
            }
            notifyPort = port
            IONotificationPortSetDispatchQueue(port, queue)

            let context = Unmanaged.passUnretained(self).toOpaque()
            let callback: IOServiceMatchingCallback = { refcon, iterator in
                guard let refcon else { return }
                let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // The iterator MUST be drained or the notification never fires again.
                monitor.drain(iterator)
                monitor.publish()
            }

            // IOServiceAddMatchingNotification consumes a reference to the
            // matching dictionary on each call, so each one gets its own.
            _ = IOServiceAddMatchingNotification(
                port, kIOMatchedNotification,
                IOServiceMatching(kIOUSBHostDeviceClassName),
                callback, context, &addedIterator
            )
            _ = IOServiceAddMatchingNotification(
                port, kIOTerminatedNotification,
                IOServiceMatching(kIOUSBHostDeviceClassName),
                callback, context, &removedIterator
            )

            drain(addedIterator)
            drain(removedIterator)
            publish()
        }
    }

    public func stop() {
        queue.async { [self] in stopUnsafely() }
    }

    private func stopUnsafely() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
        handler = nil
    }

    private func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    private func publish() {
        handler?(Self.currentDevices())
    }

    /// One synchronous pass over the bus. Cheap enough to call on every change.
    public static func currentDevices() -> [Snapshot] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching(kIOUSBHostDeviceClassName), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var snapshots: [Snapshot] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let descriptor = describe(service) else { continue }
            guard AndroidVendorIDs.isKnownAndroidVendor(descriptor.vendorID)
                    || descriptor.interfaces.contains(where: { $0.isStorageCapable }) else { continue }
            snapshots.append(Snapshot(
                descriptor: descriptor,
                exposesStorage: descriptor.interfaces.contains { $0.isStorageCapable },
                manufacturerGuess: descriptor.vendorName
                    ?? AndroidVendorIDs.manufacturer(forVendorID: descriptor.vendorID)
            ))
        }
        return snapshots
    }

    private static func describe(_ service: io_service_t) -> USBDescriptor? {
        guard let properties = copyProperties(service) else { return nil }
        guard let vendorID = properties["idVendor"] as? Int,
              let productID = properties["idProduct"] as? Int else { return nil }

        return USBDescriptor(
            vendorID: vendorID,
            productID: productID,
            vendorName: properties["USB Vendor Name"] as? String,
            productName: properties["USB Product Name"] as? String,
            serialNumber: properties["USB Serial Number"] as? String
                ?? properties[kUSBSerialNumberString as String] as? String,
            locationID: properties["locationID"] as? Int ?? 0,
            interfaces: interfaces(of: service)
        )
    }

    /// Reads the interface descriptors the device is currently publishing.
    ///
    /// Switching the phone between "charging" and "file transfer" re-enumerates
    /// the USB configuration, so this set changes live — which is exactly the
    /// signal the empty state needs in order to update the moment the user
    /// follows the instructions.
    private static func interfaces(of device: io_service_t) -> [USBInterface] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [USBInterface] = []
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            guard let properties = copyProperties(child) else { continue }
            guard let interfaceClass = properties["bInterfaceClass"] as? Int,
                  let subclass = properties["bInterfaceSubClass"] as? Int,
                  let interfaceProtocol = properties["bInterfaceProtocol"] as? Int else { continue }
            result.append(USBInterface(
                interfaceClass: interfaceClass,
                interfaceSubclass: subclass,
                interfaceProtocol: interfaceProtocol,
                name: properties["USB Interface Name"] as? String
            ))
        }
        return result
    }

    private static func copyProperties(_ service: io_service_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return dictionary
    }
}
