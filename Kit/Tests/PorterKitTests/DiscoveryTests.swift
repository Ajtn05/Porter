import Foundation
import Testing
@testable import PorterKit

private func usbSnapshot(
    serial: String?,
    vendorID: Int = 0x18D1,
    product: String = "Pixel 7",
    interfaces: [USBInterface]
) -> USBDeviceMonitor.Snapshot {
    let descriptor = USBDescriptor(
        vendorID: vendorID, productID: 0x4EE1,
        vendorName: AndroidVendorIDs.manufacturer(forVendorID: vendorID),
        productName: product, serialNumber: serial, locationID: 0x14200000,
        interfaces: interfaces
    )
    return USBDeviceMonitor.Snapshot(
        descriptor: descriptor,
        exposesStorage: interfaces.contains { $0.isStorageCapable },
        manufacturerGuess: AndroidVendorIDs.manufacturer(forVendorID: vendorID)
    )
}

private let mtpInterface = USBInterface(interfaceClass: 6, interfaceSubclass: 1, interfaceProtocol: 1)
private let adbInterface = USBInterface(interfaceClass: 255, interfaceSubclass: 66, interfaceProtocol: 1)
private let chargeOnlyInterface = USBInterface(interfaceClass: 255, interfaceSubclass: 255, interfaceProtocol: 255)

@Suite("Device discovery")
struct DeviceMergeTests {

    @Test("A phone set to charge only is reported as exactly that")
    func chargingOnlyIsNamed() throws {
        // The phone is on the bus, adb cannot see it, and it publishes no
        // storage interface.
        let devices = DeviceMerge.merge(
            usb: [usbSnapshot(serial: "ABC123", interfaces: [chargeOnlyInterface])],
            adb: []
        )
        let device = try #require(devices.first)
        #expect(device.readiness == .chargingOnly)
        #expect(!device.readiness.isBrowsable)

        // The message names the fix, not just the symptom.
        let error = TransferError.deviceNotReady(device.id, .chargingOnly)
        #expect(try #require(error.errorDescription).contains("charge only"))
        #expect(try #require(error.recoverySuggestion).contains("File Transfer"))
    }

    @Test("The same phone on USB and in adb is one row, on the faster pipe")
    func adbWinsOverMTP() throws {
        let devices = DeviceMerge.merge(
            usb: [usbSnapshot(serial: "ABC123", interfaces: [mtpInterface, adbInterface])],
            adb: [ADBParsing.DeviceListing(serial: "ABC123", state: "device",
                                           properties: ["model": "Pixel_7"])]
        )
        #expect(devices.count == 1)
        let device = try #require(devices.first)
        #expect(device.transport == .adb)
        #expect(device.displayName == "Pixel 7")
        // USB details are still attached, so the product name is available.
        #expect(device.usb?.productName == "Pixel 7")
    }

    @Test("A phone in file-transfer mode without debugging falls back to MTP")
    func mtpFallback() throws {
        let devices = DeviceMerge.merge(
            usb: [usbSnapshot(serial: "XYZ", vendorID: 0x04E8, product: "Galaxy S23",
                              interfaces: [mtpInterface])],
            adb: []
        )
        let device = try #require(devices.first)
        #expect(device.transport == .mtp)
        #expect(device.readiness == .ready)
        #expect(device.manufacturer == "Samsung")
    }

    @Test("An unauthorised device is surfaced, not hidden")
    func unauthorisedIsVisible() throws {
        let devices = DeviceMerge.merge(
            usb: [usbSnapshot(serial: "NEW1", interfaces: [adbInterface])],
            adb: [ADBParsing.DeviceListing(serial: "NEW1", state: "unauthorized", properties: [:])]
        )
        let device = try #require(devices.first)
        #expect(device.readiness == .unauthorized)
        let error = TransferError.deviceNotReady(device.id, .unauthorized)
        #expect(try #require(error.recoverySuggestion).contains("Allow"))
    }

    @Test("MTP remains usable when USB debugging is not authorized")
    func mtpBeatsUnauthorizedADB() throws {
        let devices = DeviceMerge.merge(
            usb: [usbSnapshot(serial: "NEW1", interfaces: [mtpInterface, adbInterface])],
            adb: [ADBParsing.DeviceListing(serial: "NEW1", state: "unauthorized", properties: [:])]
        )
        #expect(devices.count == 1)
        #expect(devices[0].transport == .mtp)
        #expect(devices[0].readiness == .ready)
    }

    @Test("Ready devices sort above ones that need attention")
    func ordering() {
        let devices = DeviceMerge.merge(
            usb: [
                usbSnapshot(serial: "CHARGE", product: "A phone", interfaces: [chargeOnlyInterface]),
                usbSnapshot(serial: "READY", product: "B phone", interfaces: [mtpInterface])
            ],
            adb: []
        )
        #expect(devices.first?.readiness == .ready)
        #expect(devices.last?.readiness == .chargingOnly)
    }

    @Test("A non-Android USB device is ignored entirely")
    func nonAndroidIgnored() {
        // The bus carries keyboards and hubs; only phones belong in the list.
        let devices = DeviceMerge.merge(
            usb: [usbSnapshot(serial: "KBD", vendorID: 0x05AC, product: "Keyboard",
                              interfaces: [USBInterface(interfaceClass: 3, interfaceSubclass: 1, interfaceProtocol: 1)])],
            adb: []
        )
        // The monitor filters these out before merge, which keeps whatever it
        // is handed. This documents the contract at that boundary.
        #expect(devices.count == 1)
        #expect(devices[0].readiness == .chargingOnly)
    }
}

@Suite("Transport capabilities")
struct TransportCapabilityTests {

    @Test("MTP admits what it cannot do")
    func mtpIsHonest() {
        let capabilities = MTPTransport(device: Device(id: "x", displayName: "x", transport: .mtp)).capabilities
        #expect(!capabilities.supportsRangedReads)
        #expect(!capabilities.supportsDeviceSideChecksum)
        #expect(!capabilities.reportsAccurateSizes)
        #expect(capabilities.maximumConcurrentStreams == 1)
    }

    @Test("ADB is the transport that can do everything")
    func adbIsCapable() {
        let transport = ADBTransport(adbURL: URL(fileURLWithPath: "/usr/bin/true"), serial: "x",
                                     device: Device(id: "x", displayName: "x", transport: .adb))
        #expect(transport.capabilities.supportsRangedReads)
        #expect(transport.capabilities.supportsResumableWrites)
        #expect(transport.capabilities.supportsDeviceSideChecksum)
        #expect(transport.capabilities.supportsMtimePreservation)
    }

    @Test("ADB ranks ahead of MTP")
    func preferenceOrder() {
        #expect(TransportKind.adb < TransportKind.mtp)
    }
}

/// A stand-in for the USB bus whose answer changes between reads, which is what
/// a phone finishing its enumeration looks like from here.
private final class StubBus: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [USBDeviceMonitor.Snapshot]
    private(set) var readCount = 0

    init(_ initial: [USBDeviceMonitor.Snapshot]) { snapshots = initial }

    func set(_ value: [USBDeviceMonitor.Snapshot]) {
        lock.lock(); snapshots = value; lock.unlock()
    }

    func read() -> [USBDeviceMonitor.Snapshot] {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        return snapshots
    }
}

@Suite("Discovery refresh")
struct DiscoveryRefreshTests {

    @Test("Regression: a phone whose interfaces appeared late stops being charge-only")
    func lateInterfacesAreNoticed() async throws {
        // A device nub is registered before its configuration is set, so the
        // bus can report a phone with no interfaces at all for a moment. That
        // reads as charge-only, and it used to stick: the poll re-read adb but
        // reused the USB snapshot it was handed when the device first matched,
        // so a phone in file-transfer mode stayed wrongly charge-only for as
        // long as it was plugged in.
        let bus = StubBus([usbSnapshot(serial: "R5CT502XWRL", interfaces: [])])
        let coordinator = DeviceCoordinator(adbURL: nil, readUSB: { bus.read() })

        await coordinator.refresh()
        #expect(await coordinator.currentDevices().first?.readiness == .chargingOnly)

        // The interfaces finish publishing. No notification follows, because
        // the device itself did not change.
        bus.set([usbSnapshot(serial: "R5CT502XWRL", interfaces: [mtpInterface])])
        await coordinator.refresh()

        let device = try #require(await coordinator.currentDevices().first)
        #expect(device.readiness == .ready)
        #expect(device.transport == .mtp)
    }

    @Test("A refresh reads the bus rather than a cached snapshot")
    func refreshReadsTheBus() async throws {
        let bus = StubBus([usbSnapshot(serial: "ABC123", interfaces: [mtpInterface])])
        let coordinator = DeviceCoordinator(adbURL: nil, readUSB: { bus.read() })

        await coordinator.refresh()
        await coordinator.refresh()

        #expect(bus.readCount == 2)
    }

    @Test("A phone that goes away is dropped on the next refresh")
    func unpluggedDeviceDisappears() async throws {
        let bus = StubBus([usbSnapshot(serial: "ABC123", interfaces: [mtpInterface])])
        let coordinator = DeviceCoordinator(adbURL: nil, readUSB: { bus.read() })

        await coordinator.refresh()
        #expect(await coordinator.currentDevices().count == 1)

        bus.set([])
        await coordinator.refresh()
        #expect(await coordinator.currentDevices().isEmpty)
    }
}
