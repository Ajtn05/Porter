import CryptoKit
import Foundation

public enum ChecksumAlgorithm: String, Sendable, Codable {
    /// The default, and the only algorithm both ends always support.
    ///
    /// A faster non-cryptographic hash would not help: on Apple silicon SHA-256
    /// runs on dedicated instructions at several GB/s, well above what USB 3
    /// delivers, so hashing is never the bottleneck. In exchange, every Android
    /// device ships `sha256sum` in toybox, so verifying a file in place needs no
    /// helper binary on the device.
    case sha256

    /// Fallback for older ROMs that ship `md5sum` but not `sha256sum`. Used for
    /// corruption detection only, never for security.
    case md5

    public var deviceCommand: String {
        switch self {
        case .sha256: return "sha256sum"
        case .md5: return "md5sum"
        }
    }
}

public struct Checksum: Hashable, Sendable, Codable, CustomStringConvertible {
    public let algorithm: ChecksumAlgorithm
    public let value: String

    public init(algorithm: ChecksumAlgorithm, value: String) {
        self.algorithm = algorithm
        self.value = value.lowercased()
    }

    public var description: String { "\(algorithm.rawValue):\(value)" }
}

/// Incremental hashing so a 20 GB file never has to be resident in memory, and
/// so a resumed transfer can rebuild the hash of the bytes already on disk.
public struct ChecksumHasher: Sendable {
    private var sha = SHA256()
    private var md5 = Insecure.MD5()
    public let algorithm: ChecksumAlgorithm

    public init(algorithm: ChecksumAlgorithm = .sha256) {
        self.algorithm = algorithm
    }

    public mutating func update(_ data: Data) {
        switch algorithm {
        case .sha256: sha.update(data: data)
        case .md5: md5.update(data: data)
        }
    }

    public consuming func finalize() -> Checksum {
        let hex: String
        switch algorithm {
        case .sha256: hex = sha.finalize().map { String(format: "%02x", $0) }.joined()
        case .md5: hex = md5.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return Checksum(algorithm: algorithm, value: hex)
    }
}

public enum ChecksumService {
    /// Hashes a local file in chunks. Pass `upTo` to verify only the prefix
    /// written so far, as a resume does.
    public static func hashLocalFile(
        at url: URL,
        algorithm: ChecksumAlgorithm = .sha256,
        upTo limit: Int64? = nil,
        chunkSize: Int = 4 * 1024 * 1024
    ) throws -> Checksum {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = ChecksumHasher(algorithm: algorithm)
        var remaining = limit ?? Int64.max

        while remaining > 0 {
            let want = Int(Swift.min(Int64(chunkSize), remaining))
            guard let data = try handle.read(upToCount: want), !data.isEmpty else { break }
            hasher.update(data)
            remaining -= Int64(data.count)
        }
        return hasher.finalize()
    }

    /// Parses `sha256sum`/`md5sum` output in the form toybox emits:
    /// `<hex>  <path>`, separated by two spaces, path may contain spaces.
    public static func parseSumOutput(_ output: String, algorithm: ChecksumAlgorithm) -> Checksum? {
        let line = output.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard let hex = line.split(separator: " ", maxSplits: 1).first else { return nil }
        let expectedLength = algorithm == .sha256 ? 64 : 32
        guard hex.count == expectedLength,
              hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return Checksum(algorithm: algorithm, value: String(hex))
    }
}
