import Testing
@testable import PorterKit

@Suite("Wi-Fi pairing")
struct WiFiPairingTests {

    @Test("A pairing fingerprint must be a complete SHA-256 value before networking")
    func rejectsIncompleteFingerprint() async {
        await #expect(throws: TransferError.pairingFailed(
            "enter the certificate fingerprint shown on the phone"
        )) {
            _ = try await WiFiPairing.pair(
                host: "127.0.0.1", code: "123456", expectedFingerprint: "not-a-fingerprint", clientName: "Test Mac"
            )
        }
    }
}
