import Foundation

/// Owns device discovery and vends transports.
///
/// Callers ask for a device by ID and get a readable, writable transport. This
/// type decides which one, and rebuilds it when the connection changes.
public actor DeviceCoordinator: TransportResolver {
    private let usbMonitor = USBDeviceMonitor()
    private var usbSnapshots: [USBDeviceMonitor.Snapshot] = []
    private var transports: [DeviceID: any DeviceTransport] = [:]
    private var devices: [Device] = []
    private var pollTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<[Device]>.Continuation] = [:]

    public private(set) var adbURL: URL?
    /// Nil while adb is present; set to a user-facing explanation when it is not.
    public private(set) var adbUnavailableReason: String?

    /// How the USB bus is read. Injected so the refresh path can be exercised
    /// without a phone on the other end of a cable.
    private let readUSB: @Sendable () -> [USBDeviceMonitor.Snapshot]
    public init(adbURL: URL? = nil,
                readUSB: (@Sendable () -> [USBDeviceMonitor.Snapshot])? = nil) {
        self.readUSB = readUSB ?? { USBDeviceMonitor.currentDevices() }
        self.adbURL = adbURL ?? ADBLocator.locate()
        if self.adbURL == nil {
            adbUnavailableReason = "adb was not found, so devices without USB debugging will use the slower file-transfer mode."
        }
    }

    public func deviceStream() -> AsyncStream<[Device]> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(devices)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropStream(id) }
            }
        }
    }

    private func dropStream(_ id: UUID) { continuations[id] = nil }

    public func start() {
        // Before the bus monitor, and before anything else: the MTP interface
        // has to be claimed in the same instant it is published or macOS takes
        // it. Starting the claimer here means it is armed for the whole life of
        // the app rather than only once somebody opens a device.
        MTPInterfaceClaimer.shared.start()
        usbMonitor.start { [weak self] snapshots in
            Task { await self?.applyUSBSnapshots(snapshots) }
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            // adb offers no change notification, so poll it. Attach and detach
            // still arrive instantly from the event-driven USB monitor; this
            // only covers the gap between plugging in and adb authorising.
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        usbMonitor.stop()
        MTPInterfaceClaimer.shared.stop()
    }

    private func applyUSBSnapshots(_ snapshots: [USBDeviceMonitor.Snapshot]) async {
        usbSnapshots = snapshots
        await refresh()
    }

    public func refresh() async {
        // Re-read the bus rather than trusting the last notification. The USB
        // monitor only publishes on a change it was told about, and a phone
        // that finished publishing its interfaces a moment after its device nub
        // appeared produces no second notification. Without this the phone is
        // stuck at whatever it looked like in that first instant, which for
        // file-transfer mode is no interfaces at all, and so charge-only.
        //
        // One registry pass, on the same two-second tick that already polls
        // adb.
        usbSnapshots = readUSB()

        var adbListings: [ADBParsing.DeviceListing] = []
        if let adbURL {
            adbListings = (try? await ADBTransport.listDevices(adbURL: adbURL)) ?? []
        }
        let merged = DeviceMerge.merge(usb: usbSnapshots, adb: adbListings)

        // Drop cached transports for devices that went away, so a reconnect
        // builds a fresh one instead of reusing a dead handle.
        let liveIDs = Set(merged.map(\.id))
        for id in transports.keys where !liveIDs.contains(id) {
            transports[id] = nil
        }
        for device in merged {
            if let previous = devices.first(where: { $0.id == device.id }),
               previous.transport != device.transport {
                transports[device.id] = nil
            }
        }

        guard merged != devices else { return }
        devices = merged
        for continuation in continuations.values { continuation.yield(merged) }
    }

    public func currentDevices() -> [Device] { devices }

    public func device(_ id: DeviceID) -> Device? {
        devices.first { $0.id == id }
    }

    // MARK: - TransportResolver

    public func transport(for deviceID: DeviceID) async throws -> any DeviceTransport {
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            throw TransferError.deviceNotFound(deviceID)
        }
        if let existing = transports[deviceID] { return existing }
        guard device.readiness.isBrowsable else {
            throw TransferError.deviceNotReady(deviceID, device.readiness)
        }

        let transport = try await makeTransport(for: device)
        try await transport.connect()
        guard devices.contains(where: { $0.id == deviceID && $0.transport == device.transport }) else {
            throw TransferError.deviceNotFound(deviceID)
        }
        transports[deviceID] = transport
        return transport
    }

    private func makeTransport(for device: Device) async throws -> any DeviceTransport {
        switch device.transport {
        case .adb:
            guard let adbURL else { throw ADBLocator.missingToolError }
            return ADBTransport(adbURL: adbURL, serial: device.serial ?? device.id.rawValue, device: device)
        case .mtp:
            guard let usb = device.usb else {
                // Only a wired device is ever given the MTP transport, so a
                // device that reached here without a USB descriptor came from a
                // discovery path that has no business producing one.
                throw TransferError.transportUnavailable(
                    .mtp, reason: "this device is not on the USB bus.")
            }
            let pipe = try await MTPUSBPipe.open(matching: usb, deviceID: device.id)
            return MTPTransport(device: device, pipe: pipe)
        }
    }

    /// Discards a device's cached transport so the next request reconnects.
    /// Called when a transfer reports a disconnect mid-flight.
    public func invalidateTransport(for deviceID: DeviceID) {
        transports[deviceID] = nil
    }
}
