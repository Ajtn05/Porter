import Foundation
import IOKit
import IOKit.usb

/// Claims a phone's file-transfer interface at the instant it appears on the
/// bus, and holds it until the cable is pulled.
///
/// macOS opens the still-image interface of anything that publishes one,
/// through `/usr/libexec/ptpcamerad`, and keeps it for as long as the device is
/// attached. The open is exclusive and cannot be taken back: `OpenSeize`
/// returns the same refusal, re-setting the configuration to the value it
/// already has is a no-op in `IOUSBHostFamily`, and `ptpcamerad` is protected
/// by System Integrity Protection, so signalling it does nothing. Claiming when
/// somebody clicks a device in the sidebar is therefore always too late.
///
/// What is not too late is the moment the interface is published, because both
/// processes are woken by the same match notification. This registers for the
/// still-image interface alone and opens it inside the callback, so the only
/// work between the notification and `USBInterfaceOpen` is a vendor check.
///
/// This is a race and is documented as one. It is won by being ready first,
/// which means the claimer has to be running before the phone is plugged in;
/// nothing here can rescue a phone that was already attached when the app
/// launched.
///
/// Winning costs something worth stating: while an interface is held, Photos
/// and Image Capture cannot import from that phone. Only phones are claimed,
/// never cameras, which is what the vendor check is for.
public final class MTPInterfaceClaimer: @unchecked Sendable {

    /// How one attach turned out. Kept so the diagnostic CLI can report on the
    /// race rather than leaving it to be guessed at from whether browsing
    /// worked.
    public struct Attempt: Sendable {
        public var at: Date
        public var locationID: Int
        public var vendorID: Int
        public var productID: Int
        public var productName: String?
        /// Nil when the claim succeeded.
        public var lostTo: String?
        /// PID of the owner at the time of the failed claim, when IOKit reports it.
        public var ownerPID: Int?
        public var blockedByAnotherProcess: Bool
        public var failure: String?
        /// How long the claim itself took, from the notification to the answer.
        public var duration: TimeInterval

        public var won: Bool { failure == nil }
    }

    /// One claimer per process, because the race can only be entered once: two
    /// of these would contend with each other for the same interface.
    public static let shared = MTPInterfaceClaimer()

    /// A queue of its own, at the highest quality of service a non-realtime
    /// thread can ask for. The whole point is to be scheduled ahead of another
    /// process reacting to the same notification.
    private let queue = DispatchQueue(label: "app.porter.mtp-claimer", qos: .userInteractive)
    private let lock = NSLock()

    private var notifyPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var isRunning = false

    /// Held interfaces, by the port the phone is plugged into.
    private var claims: [Int: MTPUSBInterface] = [:]
    private var attempts: [Attempt] = []
    private var onAttempt: (@Sendable (Attempt) -> Void)?

    private init() {}

    // MARK: - Lifecycle

    /// Starts watching. Safe to call more than once.
    ///
    /// `onAttempt`, when given, fires for every attach the claimer reacted to,
    /// won or lost.
    public func start(onAttempt: (@Sendable (Attempt) -> Void)? = nil) {
        queue.async { [self] in
            if let onAttempt { lock.withLock { self.onAttempt = onAttempt } }
            guard !isRunning else { return }
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
            isRunning = true
            notifyPort = port
            IONotificationPortSetDispatchQueue(port, queue)

            let context = Unmanaged.passUnretained(self).toOpaque()
            let matched: IOServiceMatchingCallback = { refcon, iterator in
                guard let refcon else { return }
                Unmanaged<MTPInterfaceClaimer>.fromOpaque(refcon)
                    .takeUnretainedValue().claimAll(from: iterator)
            }
            let terminated: IOServiceMatchingCallback = { refcon, iterator in
                guard let refcon else { return }
                Unmanaged<MTPInterfaceClaimer>.fromOpaque(refcon)
                    .takeUnretainedValue().dropTerminated(from: iterator)
            }

            // kIOFirstMatchNotification rather than kIOMatchedNotification: it
            // is delivered as soon as the interface is first matched, which is
            // the earliest moment the user client can be created, and every
            // moment after that is one ptpcamerad could be using.
            //
            // The matching dictionary narrows to the still-image class in the
            // kernel, so the callback is never woken for the dozens of other
            // interfaces on a busy bus.
            _ = IOServiceAddMatchingNotification(
                port, kIOFirstMatchNotification, Self.stillImageMatching(),
                matched, context, &matchedIterator)
            _ = IOServiceAddMatchingNotification(
                port, kIOTerminatedNotification, Self.stillImageMatching(),
                terminated, context, &terminatedIterator)

            // Both iterators must be drained or neither notification fires
            // again. Draining the matched one also picks up any phone already
            // attached, which will normally be lost: ptpcamerad claimed it
            // when it was plugged in, possibly before this process existed.
            claimAll(from: matchedIterator)
            dropTerminated(from: terminatedIterator)
        }
    }

    public func stop() {
        queue.async { [self] in
            guard isRunning else { return }
            isRunning = false
            if matchedIterator != 0 { IOObjectRelease(matchedIterator); matchedIterator = 0 }
            if terminatedIterator != 0 { IOObjectRelease(terminatedIterator); terminatedIterator = 0 }
            if let notifyPort { IONotificationPortDestroy(notifyPort) }
            notifyPort = nil
            lock.withLock {
                for interface in claims.values { interface.close() }
                claims.removeAll()
                onAttempt = nil
            }
        }
    }

    // MARK: - Handing claims out

    /// The interface held for this phone, removed from the claimer.
    ///
    /// The caller must return it with `giveBack` rather than closing it, since
    /// a closed interface goes straight back to ptpcamerad and cannot be
    /// reclaimed without pulling the cable.
    func takeClaim(matching descriptor: USBDescriptor) -> MTPUSBInterface? {
        lock.withLock { claims.removeValue(forKey: descriptor.locationID) }
    }

    func giveBack(_ interface: MTPUSBInterface, matching descriptor: USBDescriptor) {
        // Whatever the last transfer left behind is not this phone's next
        // caller's problem, and a halted endpoint stays halted until cleared.
        interface.clearStall()
        lock.withLock {
            guard claims[descriptor.locationID] == nil else {
                // The cable was pulled and put back while a transport still
                // held this one, so the claim in hand is for a connection that
                // no longer exists.
                interface.close()
                return
            }
            claims[descriptor.locationID] = interface
        }
    }

    public func isHolding(matching descriptor: USBDescriptor) -> Bool {
        lock.withLock { claims[descriptor.locationID] != nil }
    }

    /// Every attach this claimer reacted to, oldest first.
    public var history: [Attempt] {
        lock.withLock { attempts }
    }

    // MARK: - The race

    private func claimAll(from iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            claim(service)
            IOObjectRelease(service)
        }
    }

    private func claim(_ service: io_service_t) {
        let started = Date()
        let properties = Self.properties(of: service)
        guard let vendorID = properties["idVendor"] as? Int,
              let productID = properties["idProduct"] as? Int,
              let locationID = properties["locationID"] as? Int else { return }

        // Only phones. A camera's still-image interface belongs to Image
        // Capture, and taking it would break importing from a DSLR to make an
        // Android transfer marginally more likely to work.
        guard AndroidVendorIDs.isKnownAndroidVendor(vendorID) else { return }
        guard lock.withLock({ claims[locationID] == nil }) else { return }

        var attempt = Attempt(
            at: started, locationID: locationID, vendorID: vendorID, productID: productID,
            productName: properties["USB Product Name"] as? String,
            lostTo: nil, ownerPID: nil, blockedByAnotherProcess: false,
            failure: nil, duration: 0)

        do {
            let interface = try MTPUSBInterface.claim(service: service)
            lock.withLock { claims[locationID] = interface }
        } catch {
            if let busy = error as? MTPUSBInterface.ClaimBusy {
                attempt.blockedByAnotherProcess = true
                attempt.lostTo = busy.ownerName
                attempt.ownerPID = busy.ownerPID
                attempt.failure = MTPUSBLocator.exclusiveAccessError(owner: busy.ownerName).errorDescription
            } else {
                attempt.failure = (error as? TransferError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
        attempt.duration = Date().timeIntervalSince(started)

        let handler = lock.withLock { () -> (@Sendable (Attempt) -> Void)? in
            attempts.append(attempt)
            return onAttempt
        }
        handler?(attempt)
    }

    private func dropTerminated(from iterator: io_iterator_t) {
        var gone: [MTPUSBInterface] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let locationID = Self.properties(of: service)["locationID"] as? Int else { continue }
            if let interface = lock.withLock({ claims.removeValue(forKey: locationID) }) {
                gone.append(interface)
            }
        }
        // Closed outside the lock: the close path talks to IOKit and there is
        // no reason to hold every other caller up for it.
        for interface in gone { interface.close() }
    }

    // MARK: - Matching

    /// A fresh matching dictionary each time, because
    /// `IOServiceAddMatchingNotification` consumes a reference to the one it is
    /// given.
    private static func stillImageMatching() -> CFDictionary {
        let matching = IOServiceMatching(kIOUSBHostInterfaceClassName)! as NSMutableDictionary
        matching["bInterfaceClass"] = MTPUSBLocator.stillImageClass
        matching["bInterfaceSubClass"] = MTPUSBLocator.stillImageSubclass
        matching["bInterfaceProtocol"] = MTPUSBLocator.stillImageProtocol
        return matching as CFDictionary
    }

    private static func properties(of service: io_service_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dictionary
    }
}
