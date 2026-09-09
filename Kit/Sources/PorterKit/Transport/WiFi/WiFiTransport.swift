import CryptoKit
import Foundation

/// Talks to the Android companion app over the local network.
///
/// Uses TLS with a certificate pinned at pairing time and a bearer token issued
/// after the phone's code and fingerprint are verified. Traffic stays on the
/// LAN and no account is involved.
public actor WiFiTransport: DeviceTransport {
    public nonisolated let kind: TransportKind = .wifi

    public nonisolated var capabilities: TransportCapabilities {
        TransportCapabilities(
            // HTTP Range on the way down, an explicit offset on the way up.
            supportsRangedReads: true,
            supportsResumableWrites: true,
            supportsDeviceSideChecksum: true,
            supportsMtimePreservation: true,
            reportsAccurateSizes: true,
            // The network is the bottleneck, so extra streams add no
            // throughput and only make per-file progress noisier.
            maximumConcurrentStreams: 2
        )
    }

    private var device: Device
    private let baseURL: URL
    private let session: URLSession
    private let credentials: WiFiCredentials

    public init(device: Device, host: String, port: Int = 53317, credentials: WiFiCredentials = .unpaired) {
        self.device = device
        self.baseURL = URL(string: "https://\(host):\(port)")!
        self.credentials = credentials

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        // A large copy legitimately runs for hours, so only the per-request
        // timeout above should ever fire.
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        configuration.waitsForConnectivity = false
        self.session = URLSession(
            configuration: configuration,
            delegate: PinnedCertificateDelegate(fingerprint: credentials.certificateFingerprint),
            delegateQueue: nil
        )
    }

    // MARK: - Requests

    private func request(_ route: WiFiAPI.Route, body: Data? = nil, extraHeaders: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: route.url(base: baseURL))
        request.httpMethod = route.method
        if let token = credentials.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    private func send<T: Decodable>(_ route: WiFiAPI.Route, as type: T.Type) async throws -> T {
        let data = try await sendRaw(route)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TransferError.protocolError("could not read the response to \(route.method) \(route.url(base: baseURL).path)")
        }
    }

    @discardableResult
    private func sendRaw(_ route: WiFiAPI.Route) async throws -> Data {
        let (data, response) = try await session.data(for: request(route))
        try validate(response, data: data)
        return data
    }

    @discardableResult
    private func sendRaw(_ route: WiFiAPI.Route, body: some Encodable & Sendable) async throws -> Data {
        let encoded = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request(route, body: encoded))
        try validate(response, data: data)
        return data
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TransferError.protocolError("no HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw TransferError.pairingFailed("this Mac is no longer paired with the phone")
        case 404:
            throw TransferError.notFound(RemotePath("/"))
        case 507:
            throw TransferError.insufficientSpace(needed: 0, available: 0, volume: device.displayName)
        default:
            let detail = (try? JSONDecoder().decode(WiFiAPI.ErrorResponse.self, from: data))?.error
                ?? String(decoding: data.prefix(512), as: UTF8.self)
            throw TransferError.commandFailed(command: "HTTP \(http.statusCode)", exitCode: Int32(http.statusCode), stderr: detail)
        }
    }

    // MARK: - DeviceTransport

    public func currentDevice() async throws -> Device { device }

    public func connect() async throws {
        guard credentials.token != nil else {
            throw TransferError.pairingFailed("this device has not been paired yet")
        }
        let info = try await send(.info, as: WiFiAPI.DeviceInfo.self)
        device.displayName = info.name
        device.model = info.model
        device.manufacturer = info.manufacturer
        device.androidRelease = info.androidRelease
        device.readiness = .ready
    }

    public func disconnect() async {
        session.invalidateAndCancel()
    }

    public func volumes() async throws -> [StorageVolume] {
        let infos = try await send(.volumes, as: [WiFiAPI.VolumeInfo].self)
        return infos.map { info in
            StorageVolume(
                id: info.id,
                rawName: info.name,
                rootPath: RemotePath(info.path),
                totalBytes: info.totalBytes,
                freeBytes: info.freeBytes,
                isRemovable: info.removable,
                filesystem: StorageVolume.Filesystem(rawValue: info.filesystem) ?? .unknown,
                freeSpaceIsTrustworthy: true
            )
        }.disambiguated()
    }

    public func list(_ path: RemotePath) async throws -> [RemoteFile] {
        try await send(.list(path), as: [WiFiAPI.Entry].self)
            .map(\.remoteFile)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteFile? {
        do {
            return try await send(.stat(path), as: WiFiAPI.Entry.self).remoteFile
        } catch TransferError.notFound {
            return nil
        }
    }

    public func createDirectory(_ path: RemotePath) async throws {
        try await sendRaw(.makeDirectory, body: WiFiAPI.PathRequest(path: path.string))
    }

    public func remove(_ path: RemotePath, recursive: Bool) async throws {
        try await sendRaw(.remove, body: WiFiAPI.PathRequest(path: path.string, recursive: recursive))
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        try await sendRaw(.move, body: WiFiAPI.MoveRequest(from: source.string, to: destination.string))
    }

    public func freeSpace(for volume: StorageVolume) async throws -> FreeSpaceReport {
        let info = try await send(.freeSpace(volume.rootPath), as: WiFiAPI.FreeSpaceInfo.self)
        return FreeSpaceReport(reportedFreeBytes: info.freeBytes, totalBytes: info.totalBytes, isTrustworthy: true)
    }

    public func readStream(_ path: RemotePath, range: ByteRange) async throws -> AsyncThrowingStream<Data, any Error> {
        var headers: [String: String] = [:]
        if range.offset > 0 {
            headers["Range"] = "bytes=\(range.offset)-"
        }
        let request = request(.read(path), extraHeaders: headers)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TransferError.protocolError("no HTTP response")
        }
        // A server that ignores Range and replies 200 restarts the file from
        // zero, corrupting the resume, so treat it as an error.
        if range.offset > 0 && http.statusCode != 206 {
            throw TransferError.protocolError("the phone ignored the resume request")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TransferError.commandFailed(command: "GET read", exitCode: Int32(http.statusCode), stderr: "")
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    buffer.reserveCapacity(Int(TransferChunk.blockSize))
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= Int(TransferChunk.blockSize) {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func writeFile(from localURL: URL, to path: RemotePath, destinationOffset: Int64,
                          progress: @escaping @Sendable (Int64) -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(destinationOffset))

        // Upload a block at a time rather than as one long request: progress
        // is accurate, and a dropped connection costs one block, not the file.
        var offset = destinationOffset
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: Int(TransferChunk.blockSize)), !chunk.isEmpty else { break }

            var request = request(.write(path, offset: offset))
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.upload(for: request, from: chunk)
            try validate(response, data: data)

            offset += Int64(chunk.count)
            progress(Int64(chunk.count))
        }
    }

    public func checksum(_ path: RemotePath, algorithm: ChecksumAlgorithm) async throws -> Checksum? {
        let info = try await send(.checksum(path, algorithm), as: WiFiAPI.ChecksumInfo.self)
        guard let parsed = ChecksumAlgorithm(rawValue: info.algorithm) else { return nil }
        return Checksum(algorithm: parsed, value: info.value)
    }

    public func truncate(_ path: RemotePath, to length: Int64) async throws {
        // The companion truncates implicitly: a write at offset N discards
        // anything past N, so a resumed push lands on a clean boundary.
        try await sendRaw(.write(path, offset: length))
    }

    public func setModificationDate(_ date: Date, at path: RemotePath) async throws {
        try await sendRaw(.touch, body: WiFiAPI.TouchRequest(
            path: path.string, epochSeconds: Int64(date.timeIntervalSince1970)
        ))
    }
}

/// The bearer token and pinned certificate produced by pairing.
public struct WiFiCredentials: Hashable, Sendable {
    public var token: String?
    /// Lowercase hex SHA-256 of the server certificate's DER encoding.
    public var certificateFingerprint: String?

    public init(token: String? = nil, certificateFingerprint: String? = nil) {
        self.token = token
        self.certificateFingerprint = certificateFingerprint
    }

    public static let unpaired = WiFiCredentials()
}

/// Certificate pinning.
///
/// The companion app generates a self-signed certificate on first run, so the
/// system trust store cannot help us. Instead the fingerprint is captured during
/// the six-digit pairing — when the user is looking at both screens — and every
/// later connection must present exactly that certificate. An unpinned
/// connection is refused rather than trusted.
final class PinnedCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let fingerprint: String?

    init(fingerprint: String?) {
        self.fingerprint = fingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let fingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        guard digest == fingerprint.lowercased() else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
