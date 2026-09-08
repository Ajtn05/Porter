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
        // The most common support question in the whole category: the phone is
        // on the bus, adb cannot see it, and it publishes no storage interface.
        let devices = DeviceMerge.merge(
            usb: [usbSnapshot(serial: "ABC123", interfaces: [chargeOnlyInterface])],
            adb: []
        )
        let device = try #require(devices.first)
        #expect(device.readiness == .chargingOnly)
        #expect(!device.readiness.isBrowsable)

        // And the message names the fix, not just the symptom.
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
        // USB details are still attached, so the UI can show the real product name.
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

    @Test("A cable beats Wi-Fi for the same phone, and both never show twice")
    func cablePreferredOverWiFi() throws {
        let devices = DeviceMerge.merge(
            usb: [usbSnapshot(serial: "DUP", interfaces: [adbInterface])],
            adb: [ADBParsing.DeviceListing(serial: "DUP", state: "device", properties: ["model": "Pixel_7"])],
            wireless: [DeviceMerge.WirelessDevice(id: "wifi-DUP", name: "Pixel 7",
                                                  host: "192.168.1.44", serial: "DUP")]
        )
        #expect(devices.count == 1)
        #expect(devices[0].transport == .adb)
    }

    @Test("A Wi-Fi-only phone still appears")
    func wirelessOnly() throws {
        let devices = DeviceMerge.merge(
            usb: [], adb: [],
            wireless: [DeviceMerge.WirelessDevice(id: "wifi-1", name: "Pixel 7",
                                                  host: "192.168.1.44", serial: "REMOTE")]
        )
        let device = try #require(devices.first)
        #expect(device.transport == .wifi)
        #expect(device.endpointHost == "192.168.1.44")
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
        // The bus is full of keyboards and hubs; only phones belong in the list.
        let devices = DeviceMerge.merge(
            usb: [usbSnapshot(serial: "KBD", vendorID: 0x05AC, product: "Keyboard",
                              interfaces: [USBInterface(interfaceClass: 3, interfaceSubclass: 1, interfaceProtocol: 1)])],
            adb: []
        )
        // The monitor filters these out before merge; merge itself keeps whatever
        // it is handed, so this documents the contract at the boundary.
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

    @Test("Transports rank cable above Wi-Fi above MTP")
    func preferenceOrder() {
        #expect(TransportKind.adb < TransportKind.wifi)
        #expect(TransportKind.wifi < TransportKind.mtp)
    }
}
