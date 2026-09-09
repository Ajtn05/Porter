import Foundation

/// Which way an endpoint's bytes travel, in IOUSBLib's numbering.
public enum MTPUSBDirection: UInt8, Sendable {
    case toDevice = 0
    case fromDevice = 1
    case none = 2
}

/// The four USB transfer types, in IOUSBLib's numbering.
public enum MTPUSBTransferType: UInt8, Sendable {
    case control = 0
    case isochronous = 1
    case bulk = 2
    case interrupt = 3
}

/// One endpoint of an opened USB interface, as `GetPipeProperties` describes it.
public struct MTPUSBEndpoint: Hashable, Sendable {
    /// IOUSBLib numbers an interface's pipes from 1. Zero is the control pipe
    /// that every interface has and that no MTP traffic uses, so a pipe
    /// reference of zero here is a bug rather than an endpoint.
    public var pipeReference: UInt8
    public var direction: MTPUSBDirection
    public var transferType: MTPUSBTransferType
    /// The endpoint's `wMaxPacketSize`. 512 on high speed, 1024 on SuperSpeed.
    public var maximumPacketSize: Int

    public init(pipeReference: UInt8, direction: MTPUSBDirection,
                transferType: MTPUSBTransferType, maximumPacketSize: Int) {
        self.pipeReference = pipeReference
        self.direction = direction
        self.transferType = transferType
        self.maximumPacketSize = maximumPacketSize
    }
}

/// The endpoints a still-image interface publishes, sorted into the roles PTP
/// gives them.
///
/// The class specification mandates exactly three: bulk out for commands and
/// outgoing data, bulk in for incoming data and responses, and interrupt in for
/// unsolicited events. The interrupt endpoint is optional here because nothing
/// this app does reads events, and a device that omits it is still fully
/// usable for browsing and copying.
public struct MTPUSBEndpoints: Hashable, Sendable {
    public var bulkOut: MTPUSBEndpoint
    public var bulkIn: MTPUSBEndpoint
    public var interruptIn: MTPUSBEndpoint?

    public init(bulkOut: MTPUSBEndpoint, bulkIn: MTPUSBEndpoint,
                interruptIn: MTPUSBEndpoint? = nil) {
        self.bulkOut = bulkOut
        self.bulkIn = bulkIn
        self.interruptIn = interruptIn
    }

    /// Picks the bulk pair out of everything the interface publishes.
    ///
    /// The first endpoint of each direction wins. Vendors do publish extra
    /// endpoints on the same interface, and the class specification puts the
    /// three mandated ones first, so taking the first is both what the
    /// specification implies and what every other stack does.
    public static func select(from endpoints: [MTPUSBEndpoint]) throws -> MTPUSBEndpoints {
        let bulk = endpoints.filter { $0.transferType == .bulk }
        guard let bulkOut = bulk.first(where: { $0.direction == .toDevice }),
              let bulkIn = bulk.first(where: { $0.direction == .fromDevice }) else {
            throw TransferError.transportUnavailable(
                .mtp,
                reason: "this phone's file-transfer interface published \(endpoints.count) endpoints but not the bulk pair that MTP needs. Unplug the cable and plug it back in."
            )
        }
        // A zero packet size is not merely useless, it is unsafe: the session
        // divides by it to tell a short packet from a full one, so a device
        // that reports zero would take the read loop down with it.
        guard bulkOut.maximumPacketSize > 0, bulkIn.maximumPacketSize > 0 else {
            throw TransferError.transportUnavailable(
                .mtp,
                reason: "this phone reported a zero-byte packet size for its file-transfer endpoints, which no USB device can honour. Unplug the cable and plug it back in."
            )
        }
        return MTPUSBEndpoints(
            bulkOut: bulkOut,
            bulkIn: bulkIn,
            interruptIn: endpoints.first {
                $0.transferType == .interrupt && $0.direction == .fromDevice
            }
        )
    }

    /// How much room to offer the bulk-in endpoint for a read of at most
    /// `maximumLength` bytes.
    ///
    /// A bulk transfer arrives in whole packets and the controller reports an
    /// overrun if the last one has nowhere to go, so a request smaller than a
    /// packet still has to offer a whole packet and keep what it did not ask
    /// for. Rounding down above that threshold is what keeps the common case
    /// free of leftovers: the session reads a large object by asking for its
    /// whole chunk size and reads a short answer as the end of the transfer, so
    /// a chunk shortened by a leftover would truncate the file.
    public static func readCapacity(for maximumLength: Int, packetSize: Int) -> Int {
        guard packetSize > 0, maximumLength > 0 else { return 0 }
        guard maximumLength >= packetSize else { return packetSize }
        return (maximumLength / packetSize) * packetSize
    }
}

/// Translates IOKit's return codes into the errors the rest of the app already
/// knows how to present.
///
/// Kept separate from the pipe so the mapping can be tested without a phone,
/// and because the interesting half of it is judgement rather than mechanism:
/// most of these codes mean "the cable moved" and should say so rather than
/// showing a hexadecimal number to somebody copying photos.
public enum MTPUSBResult {
    /// IOUSBFamily's codes are `0xe0004xxx`. The two that matter are not
    /// importable into Swift because they are defined through a function-like
    /// macro, so they are spelled out with the header's own values.
    public static let pipeStalled = IOReturn(bitPattern: 0xe000_404f)
    public static let transactionTimeout = IOReturn(bitPattern: 0xe000_4051)

    public static func error(for code: IOReturn, during operation: String,
                             device: DeviceID) -> TransferError? {
        switch code {
        case kIOReturnSuccess:
            return nil
        case kIOReturnAborted:
            // Only ever seen after this app aborts the pipe itself, which it
            // does to unblock a read that a cancelled transfer left waiting.
            return .cancelled
        case kIOReturnNoDevice, kIOReturnNotAttached, kIOReturnNotResponding:
            return .deviceDisconnected(during: operation)
        case kIOReturnNotOpen:
            return .transportUnavailable(
                .mtp, reason: "the file-transfer connection closed. Unplug the cable and plug it back in.")
        case kIOReturnExclusiveAccess:
            // The open path has the name of the process holding the interface
            // and produces a far better sentence than this one, so this is only
            // reached if exclusive access is reported mid-transfer.
            return .transportUnavailable(
                .mtp, reason: "another app took over this phone's file-transfer connection.")
        case transactionTimeout, kIOReturnTimeout:
            return .deviceStalled(
                reason: "the phone stopped answering during \(operation). It may have locked its screen.")
        case pipeStalled:
            // The endpoint is cleared before this is thrown, so the connection
            // survives; it is the transaction that does not.
            return .protocolError("the phone stalled its file-transfer endpoint during \(operation)")
        case kIOReturnOverrun:
            return .protocolError("the phone sent more data than \(operation) had asked for")
        case kIOReturnUnderrun:
            return .protocolError("the phone sent less data than \(operation) had asked for")
        case kIOReturnNoMemory, kIOReturnNoResources:
            return .transportUnavailable(
                .mtp, reason: "the system ran out of room for a USB transfer. Closing other apps may help.")
        default:
            return .protocolError(
                String(format: "%@ failed on the USB connection (0x%08x)", operation, UInt32(bitPattern: code)))
        }
    }
}
