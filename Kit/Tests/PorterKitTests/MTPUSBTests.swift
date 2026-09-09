import Foundation
import Testing
@testable import PorterKit

/// Everything about the USB pipe that does not need a phone on the end of a
/// cable: which endpoints get picked, how much room a read offers the bus, and
/// what IOKit's return codes are turned into.
///
/// The transfers themselves are not covered here and cannot be. `porterctl mtp`
/// is the check against real hardware.
@Suite("MTP over USB")
struct MTPUSBTests {

    private func endpoint(_ pipeReference: UInt8, _ direction: MTPUSBDirection,
                          _ transferType: MTPUSBTransferType,
                          packet: Int = 512) -> MTPUSBEndpoint {
        MTPUSBEndpoint(pipeReference: pipeReference, direction: direction,
                       transferType: transferType, maximumPacketSize: packet)
    }

    // MARK: - Endpoint selection

    @Test("The bulk pair is picked out, and the event endpoint is optional")
    func selectsTheBulkPair() throws {
        let endpoints = try MTPUSBEndpoints.select(from: [
            endpoint(1, .toDevice, .bulk),
            endpoint(2, .fromDevice, .bulk),
            endpoint(3, .fromDevice, .interrupt, packet: 28)
        ])
        #expect(endpoints.bulkOut.pipeReference == 1)
        #expect(endpoints.bulkIn.pipeReference == 2)
        #expect(endpoints.interruptIn?.pipeReference == 3)
    }

    @Test("An interface with no event endpoint is still usable")
    func eventEndpointIsNotRequired() throws {
        let endpoints = try MTPUSBEndpoints.select(from: [
            endpoint(1, .toDevice, .bulk),
            endpoint(2, .fromDevice, .bulk)
        ])
        #expect(endpoints.interruptIn == nil)
    }

    @Test("Extra endpoints past the mandated three are ignored")
    func extraEndpointsAreIgnored() throws {
        // Vendors do publish more than the class requires. The specification
        // puts the mandated three first, so the first of each direction wins.
        let endpoints = try MTPUSBEndpoints.select(from: [
            endpoint(1, .toDevice, .bulk, packet: 512),
            endpoint(2, .fromDevice, .bulk, packet: 512),
            endpoint(3, .fromDevice, .interrupt, packet: 28),
            endpoint(4, .toDevice, .bulk, packet: 64),
            endpoint(5, .fromDevice, .bulk, packet: 64)
        ])
        #expect(endpoints.bulkOut.pipeReference == 1)
        #expect(endpoints.bulkIn.pipeReference == 2)
        #expect(endpoints.bulkIn.maximumPacketSize == 512)
    }

    @Test("An interface with only one direction of bulk is refused")
    func halfAnInterfaceIsRefused() {
        #expect(throws: TransferError.self) {
            try MTPUSBEndpoints.select(from: [
                endpoint(1, .fromDevice, .bulk),
                endpoint(2, .fromDevice, .interrupt)
            ])
        }
    }

    @Test("A control-only interface is refused rather than driven as bulk")
    func controlOnlyIsRefused() {
        #expect(throws: TransferError.self) {
            try MTPUSBEndpoints.select(from: [endpoint(1, .toDevice, .control)])
        }
    }

    @Test("A zero-byte packet size is refused, because the session divides by it")
    func zeroPacketSizeIsRefused() {
        // Regression: the session reads a short packet by taking the remainder
        // of a chunk against this number, so letting a zero through would take
        // the read loop down rather than fail the connection.
        #expect(throws: TransferError.self) {
            try MTPUSBEndpoints.select(from: [
                endpoint(1, .toDevice, .bulk, packet: 512),
                endpoint(2, .fromDevice, .bulk, packet: 0)
            ])
        }
    }

    // MARK: - Read sizing

    @Test("A read of a packet or more is rounded down and never overruns the request")
    func readCapacityRoundsDown() {
        #expect(MTPUSBEndpoints.readCapacity(for: 512 * 1024, packetSize: 512) == 512 * 1024)
        #expect(MTPUSBEndpoints.readCapacity(for: 1000, packetSize: 512) == 512)
        #expect(MTPUSBEndpoints.readCapacity(for: 1024, packetSize: 1024) == 1024)
        // Rounding up here would hand the session a chunk longer than it asked
        // for, and its byte accounting would then run past the end of the
        // container.
        for length in [512, 700, 1023, 1024, 4096, 65_535] {
            #expect(MTPUSBEndpoints.readCapacity(for: length, packetSize: 512) <= length)
        }
    }

    @Test("A read shorter than one packet still offers the bus a whole packet")
    func readCapacityRoundsUpBelowOnePacket() {
        // The tail of a container of declared length asks for a handful of
        // bytes. Offering only those would have the controller report an
        // overrun when the device answers with a full packet.
        #expect(MTPUSBEndpoints.readCapacity(for: 4, packetSize: 512) == 512)
        #expect(MTPUSBEndpoints.readCapacity(for: 511, packetSize: 512) == 512)
    }

    @Test("A read of nothing asks for nothing")
    func readCapacityOfZero() {
        #expect(MTPUSBEndpoints.readCapacity(for: 0, packetSize: 512) == 0)
        #expect(MTPUSBEndpoints.readCapacity(for: 512, packetSize: 0) == 0)
    }

    // MARK: - IOKit return codes

    @Test("Success is not an error")
    func successIsNil() {
        #expect(MTPUSBResult.error(for: kIOReturnSuccess, during: "reading",
                                   device: DeviceID("x")) == nil)
    }

    @Test("A pulled cable is a disconnect, not a protocol failure")
    func detachIsADisconnect() {
        for code in [kIOReturnNoDevice, kIOReturnNotAttached, kIOReturnNotResponding] {
            let error = MTPUSBResult.error(for: code, during: "reading", device: DeviceID("x"))
            guard case .deviceDisconnected(let during) = error else {
                Issue.record("\(code) should be a disconnect, got \(String(describing: error))")
                continue
            }
            #expect(during == "reading")
        }
    }

    @Test("An aborted transfer is a cancellation, which is what aborts it")
    func abortIsCancellation() {
        #expect(MTPUSBResult.error(for: kIOReturnAborted, during: "reading",
                                   device: DeviceID("x")) == .cancelled)
    }

    @Test("A timed-out transfer says the phone may have locked its screen")
    func timeoutBlamesTheLockScreen() {
        let error = MTPUSBResult.error(for: MTPUSBResult.transactionTimeout,
                                       during: "listing a folder", device: DeviceID("x"))
        guard case .deviceStalled(let reason) = error else {
            Issue.record("a timeout should stall, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("listing a folder"))
    }

    @Test("An unrecognised code still names the operation and prints its number")
    func unknownCodeIsStillLegible() {
        let error = MTPUSBResult.error(for: IOReturn(bitPattern: 0xe000_4099),
                                       during: "opening a session", device: DeviceID("x"))
        guard case .protocolError(let message) = error else {
            Issue.record("expected a protocol error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("opening a session"))
        #expect(message.contains("0xe0004099"))
    }

    // MARK: - Who holds the interface

    @Test("IOKit's owner string yields a pid and a process name")
    func ownerStringParses() {
        let owner = MTPUSBLocator.process(from: "pid 96659, ptpcamerad")
        #expect(owner?.pid == 96659)
        #expect(owner?.name == "ptpcamerad")
    }

    @Test("An owner string without a name is not an owner")
    func malformedOwnerStringIsNil() {
        #expect(MTPUSBLocator.process(from: "pid 431") == nil)
        #expect(MTPUSBLocator.process(from: "pid 431, ") == nil)
        #expect(MTPUSBLocator.process(from: "") == nil)
    }

    @Test("A process name containing a comma keeps the rest of its name")
    func nameWithACommaSurvives() {
        // The string is split once, so a name with punctuation in it is not
        // truncated at the first comma.
        #expect(MTPUSBLocator.process(from: "pid 12, Adobe Creative Cloud, Helper")?.name
                == "Adobe Creative Cloud, Helper")
    }

    @Test("An interface held by ptpcamerad points at the two things that do work")
    func ptpcameradErrorOffersAWayOut() {
        let error = MTPUSBLocator.exclusiveAccessError(owner: "ptpcamerad")
        guard case .transportUnavailable(let kind, let reason) = error else {
            Issue.record("expected the transport to be unavailable")
            return
        }
        #expect(kind == .mtp)
        // ptpcamerad is protected by System Integrity Protection, so quitting
        // it is not advice anybody can act on. Replugging with the app running
        // enters the claim race, and USB debugging avoids the whole problem.
        #expect(reason.contains("plug it back in"))
        #expect(reason.contains("USB debugging"))
        #expect(!reason.contains("Quit"))
    }

    @Test("An interface held by an ordinary app suggests quitting it")
    func ordinaryHolderIsWorthQuitting() {
        let error = MTPUSBLocator.exclusiveAccessError(owner: "Android File Transfer")
        guard case .transportUnavailable(_, let reason) = error else {
            Issue.record("expected the transport to be unavailable")
            return
        }
        #expect(reason.contains("Android File Transfer"))
        #expect(reason.contains("Quit"))
    }

    @Test("An interface with no named owner still says something useful")
    func unnamedOwnerStillExplains() {
        guard case .transportUnavailable(_, let reason) =
                MTPUSBLocator.exclusiveAccessError(owner: nil) else {
            Issue.record("expected the transport to be unavailable")
            return
        }
        #expect(!reason.isEmpty)
        #expect(reason.contains("USB debugging"))
    }

    // MARK: - The claim race

    @Test("A claimer with nothing claimed hands out nothing")
    func claimerStartsEmpty() {
        // The shared claimer is not started here, so this pins the one
        // behaviour that must hold before the race is entered: asking for a
        // claim that was never made returns nil rather than an interface in
        // some half-open state.
        let descriptor = USBDescriptor(vendorID: 0x04E8, productID: 0x6860, locationID: 0x0110_0000)
        #expect(!MTPInterfaceClaimer.shared.isHolding(matching: descriptor))
    }
}
