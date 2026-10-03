import Foundation
import IOKit
import IOKit.usb

/// The bulk endpoints of a phone's still-image interface, driven through
/// IOUSBLib.
///
/// This is the layer `MTPSession` was written against and the only part of the
/// MTP stack that needs a phone on the end of a cable. Everything above it is
/// pure protocol and is tested without hardware.
///
/// IOUSBLib's synchronous calls block the calling thread for as long as the
/// transfer takes, so every one of them runs on this object's own serial queue
/// and is bridged back to `async`. Serial is also correct rather than merely
/// convenient: MTP allows one transaction in flight, so there is never a second
/// transfer to overlap with.
public final class MTPUSBPipe: MTPPipe, @unchecked Sendable {

    public struct Options: Sendable {
        /// Milliseconds a transfer may go without moving a byte before IOUSBLib
        /// abandons it.
        ///
        /// Never zero, which IOUSBLib reads as "wait forever": a phone that
        /// locks its screen mid-listing stops answering entirely, and forever
        /// is the one answer the app cannot show to somebody waiting on a
        /// spinner.
        public var noDataTimeout: UInt32
        /// Milliseconds a single transfer may take in total. A 512 KB read
        /// moves in tens of milliseconds at USB 2 speeds, so this only ever
        /// fires on a device that has wedged.
        public var completionTimeout: UInt32

        public init(noDataTimeout: UInt32 = 10_000, completionTimeout: UInt32 = 60_000) {
            self.noDataTimeout = noDataTimeout
            self.completionTimeout = completionTimeout
        }
    }

    /// `wMaxPacketSize` of the bulk-in endpoint, which is what tells a short
    /// packet from a full one.
    public nonisolated let maximumPacketSize: Int

    private let queue = DispatchQueue(label: "app.porter.mtp-usb")
    private let deviceID: DeviceID
    private let options: Options
    private let interface: MTPUSBInterface
    /// What to do with the interface when this pipe is finished with it.
    ///
    /// A pipe that claimed its own interface closes it. A pipe handed one by
    /// `MTPInterfaceClaimer` gives it back still open, because closing it would
    /// hand the interface straight back to ptpcamerad and the claim cannot be
    /// retaken until the cable is pulled.
    private let release: @Sendable (MTPUSBInterface) -> Void

    /// Bytes read past what the caller asked for.
    ///
    /// A bulk-in transfer is measured in whole packets, so a request for fewer
    /// bytes than one packet still has to offer the device a full packet of
    /// room or the controller reports an overrun. Whatever arrives beyond the
    /// request is held here rather than dropped, because those bytes are the
    /// front of the next container.
    private var residue = Data()

    private init(interface: MTPUSBInterface, deviceID: DeviceID, options: Options,
                 release: @escaping @Sendable (MTPUSBInterface) -> Void) {
        self.interface = interface
        self.deviceID = deviceID
        self.options = options
        self.release = release
        self.maximumPacketSize = interface.endpoints.bulkIn.maximumPacketSize
    }

    /// Opens the still-image interface of the phone `descriptor` names.
    ///
    /// Takes the interface `MTPInterfaceClaimer` is already holding for this
    /// phone when there is one, and claims it directly when there is not.
    /// Claiming directly is the path that usually fails: macOS's own
    /// `ptpcamerad` opens the still-image interface of anything publishing one
    /// at the moment it appears on the bus and holds it until the cable is
    /// pulled, so by the time somebody clicks a device in the sidebar the
    /// interface is long gone. The error thrown in that case names the process
    /// holding it, because "no storage found" for what is really "something
    /// else has this phone open" is the most misleading thing this app could
    /// say.
    public static func open(matching descriptor: USBDescriptor, deviceID: DeviceID,
                            options: Options = Options()) async throws -> MTPUSBPipe {
        if let claimed = MTPInterfaceClaimer.shared.takeClaim(matching: descriptor) {
            return MTPUSBPipe(interface: claimed, deviceID: deviceID, options: options) {
                MTPInterfaceClaimer.shared.giveBack($0, matching: descriptor)
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            // Not this instance's queue, which does not exist yet.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let interface = try MTPUSBInterface.claim(matching: descriptor)
                    continuation.resume(returning: MTPUSBPipe(
                        interface: interface, deviceID: deviceID, options: options,
                        release: { $0.close() }))
                } catch let busy as MTPUSBInterface.ClaimBusy {
                    continuation.resume(throwing: MTPUSBLocator.exclusiveAccessError(owner: busy.ownerName))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - MTPPipe

    public func write(_ data: Data) async throws {
        try await onQueue { [self] in
            let code = interface.write(data, to: interface.endpoints.bulkOut.pipeReference,
                                       options: options)
            try throwing(code, during: "sending \(data.count) bytes to the phone")
        }
    }

    public func read(maximumLength: Int) async throws -> Data {
        guard maximumLength > 0 else { return Data() }
        return try await onQueue { [self] in
            if !residue.isEmpty {
                let count = Swift.min(maximumLength, residue.count)
                defer { residue = Data(residue.dropFirst(count)) }
                return Data(residue.prefix(count))
            }

            let capacity = MTPUSBEndpoints.readCapacity(
                for: maximumLength, packetSize: interface.endpoints.bulkIn.maximumPacketSize)
            var buffer = [UInt8](repeating: 0, count: capacity)
            var received = UInt32(capacity)
            let code = interface.read(into: &buffer, count: &received,
                                      from: interface.endpoints.bulkIn.pipeReference,
                                      options: options)
            try throwing(code, during: "reading from the phone")

            let count = Int(received)
            guard count > maximumLength else { return Data(buffer.prefix(count)) }
            residue = Data(buffer[maximumLength ..< count])
            return Data(buffer.prefix(maximumLength))
        }
    }

    public func close() async {
        try? await onQueue { [self] in
            residue = Data()
            release(interface)
        }
    }

    // MARK: - Plumbing

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Turns a failed transfer into an error, clearing the endpoint first when
    /// the failure left it unusable.
    private func throwing(_ code: IOReturn, during operation: String) throws {
        guard let error = MTPUSBResult.error(for: code, during: operation, device: deviceID) else {
            return
        }
        // A stalled or timed-out endpoint stays stalled until it is cleared,
        // and every later transfer on it fails the same way. Clearing here is
        // what lets one refused transaction be one refused transaction rather
        // than the end of the session.
        if code == MTPUSBResult.pipeStalled || code == MTPUSBResult.transactionTimeout
            || code == kIOReturnTimeout {
            interface.clearStall()
            residue = Data()
        }
        throw error
    }
}

// MARK: - IOUSBLib

/// The IOKit plugin machinery, kept in one place so nothing above it handles a
/// raw pointer.
///
/// Every method here blocks. It runs on `MTPUSBPipe`'s queue once a pipe owns
/// it, and on the claimer's notification queue before that.
final class MTPUSBInterface {
    struct ClaimBusy: Error {
        let ownerName: String?
        let ownerPID: Int?
    }

    let endpoints: MTPUSBEndpoints

    private var interface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>?
    private var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?

    private init(interface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>,
                 plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>,
                 endpoints: MTPUSBEndpoints) {
        self.interface = interface
        self.plugin = plugin
        self.endpoints = endpoints
    }

    deinit { close() }

    static func claim(matching descriptor: USBDescriptor) throws -> MTPUSBInterface {
        guard let service = MTPUSBLocator.stillImageInterface(matching: descriptor) else {
            throw TransferError.transportUnavailable(
                .mtp,
                reason: "this phone is not offering a file-transfer connection. On the phone, tap the USB notification and choose File transfer."
            )
        }
        defer { IOObjectRelease(service) }
        return try claim(service: service)
    }

    /// Claims an interface already in hand.
    ///
    /// Separate from the lookup above because the claimer catches the interface
    /// as the notification hands it over, and every microsecond spent looking it
    /// up again is a microsecond of the race given away.
    static func claim(service: io_service_t) throws -> MTPUSBInterface {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let created = IOCreatePlugInInterfaceForService(
            service, MTPUSBLocator.interfaceUserClientTypeID, MTPUSBLocator.plugInInterfaceID,
            &plugin, &score)
        guard created == kIOReturnSuccess, let plugin else {
            throw TransferError.transportUnavailable(
                .mtp,
                reason: String(format: "macOS refused a connection to this phone's file-transfer interface (0x%08x).",
                               UInt32(bitPattern: created)))
        }

        var opaque: LPVOID?
        let queried = withUnsafeMutablePointer(to: &opaque) { pointer in
            plugin.pointee!.pointee.QueryInterface(
                plugin, CFUUIDGetUUIDBytes(MTPUSBLocator.interfaceInterfaceID), pointer)
        }
        guard queried == S_OK, let opaque else {
            IODestroyPlugInInterface(plugin)
            throw TransferError.transportUnavailable(
                .mtp, reason: "macOS has no USB driver interface for this phone's file-transfer connection.")
        }
        let interface = opaque.bindMemory(
            to: UnsafeMutablePointer<IOUSBInterfaceInterface>?.self, capacity: 1)

        var opened = interface.pointee!.pointee.USBInterfaceOpen(interface)
        if opened == kIOReturnExclusiveAccess {
            // Seize is the documented way to take an interface from another
            // user-space client. It is tried because it costs one call and
            // works against ordinary applications; it does not work against
            // ptpcamerad, whose hold survives it.
            opened = interface.pointee!.pointee.USBInterfaceOpenSeize(interface)
        }
        guard opened == kIOReturnSuccess else {
            _ = interface.pointee!.pointee.Release(interface)
            IODestroyPlugInInterface(plugin)
            if opened == kIOReturnExclusiveAccess {
                let owner = MTPUSBLocator.exclusiveOwnerProcess(of: service)
                throw ClaimBusy(ownerName: owner?.name, ownerPID: owner?.pid)
            }
            throw TransferError.transportUnavailable(
                .mtp,
                reason: String(format: "this phone's file-transfer connection could not be opened (0x%08x). Unplug the cable and plug it back in.",
                               UInt32(bitPattern: opened)))
        }

        do {
            let endpoints = try MTPUSBEndpoints.select(from: Self.endpoints(of: interface))
            return MTPUSBInterface(interface: interface, plugin: plugin, endpoints: endpoints)
        } catch {
            _ = interface.pointee!.pointee.USBInterfaceClose(interface)
            _ = interface.pointee!.pointee.Release(interface)
            IODestroyPlugInInterface(plugin)
            throw error
        }
    }

    /// Reads the pipe table of an opened interface.
    private static func endpoints(
        of interface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>
    ) -> [MTPUSBEndpoint] {
        var count: UInt8 = 0
        guard interface.pointee!.pointee.GetNumEndpoints(interface, &count) == kIOReturnSuccess,
              count > 0 else { return [] }

        var result: [MTPUSBEndpoint] = []
        // Pipe references start at 1; 0 is the control pipe.
        for pipeReference in 1 ... count {
            var direction: UInt8 = 0
            var number: UInt8 = 0
            var transferType: UInt8 = 0
            var maximumPacketSize: UInt16 = 0
            var interval: UInt8 = 0
            guard interface.pointee!.pointee.GetPipeProperties(
                interface, pipeReference, &direction, &number, &transferType,
                &maximumPacketSize, &interval) == kIOReturnSuccess else { continue }
            guard let direction = MTPUSBDirection(rawValue: direction),
                  let transferType = MTPUSBTransferType(rawValue: transferType) else { continue }
            result.append(MTPUSBEndpoint(
                pipeReference: pipeReference,
                direction: direction,
                transferType: transferType,
                maximumPacketSize: Int(maximumPacketSize)
            ))
        }
        return result
    }

    func write(_ data: Data, to pipeReference: UInt8, options: MTPUSBPipe.Options) -> IOReturn {
        guard let interface else { return kIOReturnNotOpen }
        guard !data.isEmpty else {
            // A genuine zero-length packet, which is a terminator rather than a
            // no-op, so it has to reach the wire.
            var nothing: UInt8 = 0
            return interface.pointee!.pointee.WritePipeTO(
                interface, pipeReference, &nothing, 0,
                options.noDataTimeout, options.completionTimeout)
        }
        var bytes = [UInt8](data)
        return interface.pointee!.pointee.WritePipeTO(
            interface, pipeReference, &bytes, UInt32(bytes.count),
            options.noDataTimeout, options.completionTimeout)
    }

    func read(into buffer: inout [UInt8], count: inout UInt32, from pipeReference: UInt8,
              options: MTPUSBPipe.Options) -> IOReturn {
        guard let interface else { return kIOReturnNotOpen }
        return interface.pointee!.pointee.ReadPipeTO(
            interface, pipeReference, &buffer, &count,
            options.noDataTimeout, options.completionTimeout)
    }

    /// Clears a halted endpoint at both ends.
    ///
    /// Both ends matters: clearing only the host's view leaves the phone still
    /// believing the endpoint is halted, and the next transfer fails the same
    /// way.
    func clearStall() {
        guard let interface else { return }
        for endpoint in [endpoints.bulkIn, endpoints.bulkOut] {
            _ = interface.pointee!.pointee.AbortPipe(interface, endpoint.pipeReference)
            _ = interface.pointee!.pointee.ClearPipeStallBothEnds(interface, endpoint.pipeReference)
        }
    }

    func close() {
        guard let interface else { return }
        // Aborting first unblocks any transfer still waiting on the device, so
        // closing after a disconnect does not sit out the completion timeout.
        for endpoint in [endpoints.bulkIn, endpoints.bulkOut] {
            _ = interface.pointee!.pointee.AbortPipe(interface, endpoint.pipeReference)
        }
        _ = interface.pointee!.pointee.USBInterfaceClose(interface)
        _ = interface.pointee!.pointee.Release(interface)
        self.interface = nil
        if let plugin {
            IODestroyPlugInInterface(plugin)
            self.plugin = nil
        }
    }
}

/// Finding a phone's still-image interface on the USB bus, and finding out who
/// else has it.
public enum MTPUSBLocator {

    /// The class, subclass, and protocol triple Android publishes MTP under.
    /// Matched in the registry rather than filtered afterwards, so a phone with
    /// six interfaces costs one lookup.
    static let stillImageClass = 6
    static let stillImageSubclass = 1
    static let stillImageProtocol = 1

    // The plugin UUIDs are defined in IOKit's headers through a function-like
    // macro, which Swift does not import, so they are rebuilt here from the
    // same bytes.
    ///
    /// Computed rather than stored because a `CFUUID` is a class and so cannot
    /// be a global constant under strict concurrency checking. There is nothing
    /// to cache anyway: `CFUUIDGetConstantUUIDWithBytes` returns the same
    /// interned object every time.
    static var plugInInterfaceID: CFUUID {
        uuid(0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
             0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    }
    static var interfaceUserClientTypeID: CFUUID {
        uuid(0x2D, 0x97, 0x86, 0xC6, 0x9E, 0xF3, 0x11, 0xD4,
             0xAD, 0x51, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
    }
    /// `kIOUSBInterfaceInterfaceID942`, which is what `IOUSBInterfaceInterface`
    /// itself is typedef'd to on every macOS this app runs on.
    static var interfaceInterfaceID: CFUUID {
        uuid(0x87, 0x52, 0x66, 0x3B, 0xC0, 0x7B, 0x4B, 0xAE,
             0x95, 0x84, 0x22, 0x03, 0x2F, 0xAB, 0x9C, 0x5A)
    }

    private static func uuid(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8,
                             _ b4: UInt8, _ b5: UInt8, _ b6: UInt8, _ b7: UInt8,
                             _ b8: UInt8, _ b9: UInt8, _ b10: UInt8, _ b11: UInt8,
                             _ b12: UInt8, _ b13: UInt8, _ b14: UInt8, _ b15: UInt8) -> CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil, b0, b1, b2, b3, b4, b5, b6, b7,
                                       b8, b9, b10, b11, b12, b13, b14, b15)
    }

    /// What the bus says about a phone's file-transfer interface without
    /// claiming it.
    ///
    /// Claiming is the step that fails, and it is not free to attempt: opening
    /// the interface takes it away from whatever else is using it when it does
    /// succeed. A diagnostic looks first.
    public struct Report: Sendable {
        /// False when the phone is on the bus but not offering file transfer,
        /// which is the charge-only case.
        public var publishesInterface: Bool
        /// The process holding the exclusive open, if it is not this one.
        public var exclusiveOwner: String?

        public init(publishesInterface: Bool, exclusiveOwner: String?) {
            self.publishesInterface = publishesInterface
            self.exclusiveOwner = exclusiveOwner
        }
    }

    public static func inspect(matching descriptor: USBDescriptor) -> Report {
        guard let service = stillImageInterface(matching: descriptor) else {
            return Report(publishesInterface: false, exclusiveOwner: nil)
        }
        defer { IOObjectRelease(service) }
        return Report(publishesInterface: true, exclusiveOwner: exclusiveOwner(of: service))
    }

    /// The still-image interface belonging to one phone, or nil when it is not
    /// publishing one.
    ///
    /// Matched by `locationID`, which is the physical port and so the only
    /// identifier that stays right when two of the same model are plugged in.
    /// Vendor and product stand in when the descriptor was built without one.
    /// The caller owns the returned service and must release it.
    static func stillImageInterface(matching descriptor: USBDescriptor) -> io_service_t? {
        guard let matching = IOServiceMatching(kIOUSBHostInterfaceClassName) else { return nil }
        let criteria = matching as NSMutableDictionary
        criteria["bInterfaceClass"] = stillImageClass
        criteria["bInterfaceSubClass"] = stillImageSubclass
        criteria["bInterfaceProtocol"] = stillImageProtocol

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, criteria as CFDictionary, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let properties = self.properties(of: service)
            let location = properties["locationID"] as? Int
            let matches = descriptor.locationID != 0
                ? location == descriptor.locationID
                : (properties["idVendor"] as? Int) == descriptor.vendorID
                    && (properties["idProduct"] as? Int) == descriptor.productID
            if matches { return service }
            IOObjectRelease(service)
        }
        return nil
    }

    /// The process holding the exclusive open on `service`, or nil when the
    /// interface is free or this process is the one holding it.
    ///
    /// `IOUSBHostInterface` publishes the owner as a property, in the same
    /// `pid 431, Finder` shape IOKit uses everywhere else. That is worth
    /// reading rather than inferring from the user clients attached to the
    /// nub: every process that so much as enumerates the bus leaves a user
    /// client behind, so on a typical Mac the list of clients names two or
    /// three innocents alongside the one that matters.
    static func exclusiveOwner(of service: io_service_t) -> String? {
        exclusiveOwnerProcess(of: service)?.name
    }

    static func exclusiveOwnerProcess(of service: io_service_t) -> (pid: Int, name: String)? {
        guard let raw = properties(of: service)["UsbExclusiveOwner"] as? String,
              let owner = process(from: raw) else { return nil }
        guard owner.pid != Int(ProcessInfo.processInfo.processIdentifier) else { return nil }
        return owner
    }

    /// Splits IOKit's `pid 431, Finder` shape into its two halves.
    public static func process(from reference: String) -> (pid: Int, name: String)? {
        let parts = reference.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        guard let pid = Int(parts[0].replacingOccurrences(of: "pid ", with: "")) else { return nil }
        return (pid, parts[1])
    }

    /// The error for an interface something else already holds.
    ///
    /// Written as advice rather than as a diagnosis when the holder is
    /// `ptpcamerad`, because there is no fix the app can apply: it is protected
    /// by System Integrity Protection, so it cannot be signalled, seized from,
    /// or asked to let go. An ordinary application can simply be quit, so that
    /// is what the message says instead.
    public static func exclusiveAccessError(owner: String?) -> TransferError {
        guard let owner else {
            return .transportUnavailable(
                .mtp,
                reason: "another program on this Mac has this phone's file-transfer connection open. Quit it, or turn on USB debugging to use the faster ADB transport."
            )
        }
        if owner == "ptpcamerad" {
            return .transportUnavailable(
                .mtp,
                reason: "macOS has this phone open as a camera, and will not share it. Unplug the cable and plug it back in with Porter already running, or turn on USB debugging to use the faster ADB transport."
            )
        }
        return .transportUnavailable(
            .mtp,
            reason: "\(owner) has this phone's file-transfer connection open. Quit it and try again."
        )
    }

    private static func properties(of service: io_service_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dictionary
    }
}
