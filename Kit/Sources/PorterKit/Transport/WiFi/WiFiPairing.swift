import CryptoKit
import Foundation
import Security

/// The credentials and display name returned by a successful Wi-Fi pairing.
public struct WiFiPairingResult: Sendable {
    public var deviceName: String
    public var credentials: WiFiCredentials

    public init(deviceName: String, credentials: WiFiCredentials) {
        self.deviceName = deviceName
        self.credentials = credentials
    }
}

/// Performs the one request that is allowed before a Wi-Fi device is pinned.
///
/// The companion uses a self-signed certificate. The user transcribes its
/// displayed SHA-256 fingerprint, which must match both the TLS leaf and the
/// pairing response before the Mac saves credentials. Every later request is
/// made by `WiFiTransport`, which rejects a different certificate.
public enum WiFiPairing {
    public static func pair(host: String, port: Int = 53317, code: String,
                            expectedFingerprint: String, clientName: String) async throws -> WiFiPairingResult {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty,
              !cleanHost.contains("://"),
              !cleanHost.contains("/"),
              !cleanHost.contains(where: \.isWhitespace) else {
            throw TransferError.pairingFailed("enter the phone's local IP address or host name")
        }
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            throw TransferError.pairingFailed("enter the six-digit code shown on the phone")
        }
        let expectedFingerprint = expectedFingerprint
            .lowercased()
            .filter { $0.isHexDigit }
        guard expectedFingerprint.count == 64 else {
            throw TransferError.pairingFailed("enter the certificate fingerprint shown on the phone")
        }
        guard let url = URL(string: "https://\(cleanHost):\(port)/\(WiFiAPI.version)/pair") else {
            throw TransferError.pairingFailed("the phone address is not valid")
        }

        let trustDelegate = PairingTrustDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: trustDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(WiFiAPI.PairRequest(code: code, clientName: clientName))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TransferError.pairingFailed("the phone did not return an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(WiFiAPI.ErrorResponse.self, from: data))?.error
                ?? String(decoding: data.prefix(512), as: UTF8.self)
            throw TransferError.pairingFailed(detail.isEmpty ? "the phone refused the pairing request" : detail)
        }

        let paired: WiFiAPI.PairResponse
        do {
            paired = try JSONDecoder().decode(WiFiAPI.PairResponse.self, from: data)
        } catch {
            throw TransferError.pairingFailed("the phone sent an invalid pairing response")
        }
        guard !paired.token.isEmpty, let observedFingerprint = trustDelegate.fingerprint else {
            throw TransferError.pairingFailed("the phone did not present a certificate")
        }
        guard observedFingerprint == expectedFingerprint,
              paired.certificateFingerprint.lowercased() == expectedFingerprint else {
            throw TransferError.pairingFailed("the phone's certificate changed while pairing")
        }

        return WiFiPairingResult(
            deviceName: paired.deviceName,
            credentials: WiFiCredentials(token: paired.token, certificateFingerprint: observedFingerprint)
        )
    }
}

/// Accepts the companion's self-signed certificate only long enough to capture
/// its fingerprint. The user-provided fingerprint is checked before a result
/// is saved, so an active local-network peer cannot substitute its certificate.
private final class PairingTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedFingerprint: String?

    var fingerprint: String? { lock.withLock { capturedFingerprint } }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificates.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let der = SecCertificateCopyData(certificate) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        lock.withLock { capturedFingerprint = fingerprint }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
