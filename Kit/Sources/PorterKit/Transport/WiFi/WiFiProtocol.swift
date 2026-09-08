import Foundation

/// The wire format between the Mac app and the Android companion.
///
/// Deliberately small and boring: JSON for metadata, raw bytes with HTTP `Range`
/// for content. Range support is the whole reason this transport can resume,
/// which is the one thing MTP cannot do.
public enum WiFiAPI {
    public static let version = "v1"

    public enum Route: Sendable {
        case info
        case pair
        case volumes
        case list(RemotePath)
        case stat(RemotePath)
        case makeDirectory
        case remove
        case move
        case read(RemotePath)
        case write(RemotePath, offset: Int64)
        case checksum(RemotePath, ChecksumAlgorithm)
        case touch
        case freeSpace(RemotePath)

        public var method: String {
            switch self {
            case .info, .volumes, .list, .stat, .read, .checksum, .freeSpace: return "GET"
            case .pair, .makeDirectory, .remove, .move, .touch: return "POST"
            case .write: return "PUT"
            }
        }

        public func url(base: URL) -> URL {
            var components = URLComponents(
                url: base.appendingPathComponent(WiFiAPI.version).appendingPathComponent(pathComponent),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = queryItems.isEmpty ? nil : queryItems
            return components.url!
        }

        private var pathComponent: String {
            switch self {
            case .info: return "info"
            case .pair: return "pair"
            case .volumes: return "volumes"
            case .list: return "list"
            case .stat: return "stat"
            case .makeDirectory: return "mkdir"
            case .remove: return "delete"
            case .move: return "move"
            case .read: return "read"
            case .write: return "write"
            case .checksum: return "checksum"
            case .touch: return "touch"
            case .freeSpace: return "free"
            }
        }

        private var queryItems: [URLQueryItem] {
            switch self {
            case .list(let path), .stat(let path), .read(let path), .freeSpace(let path):
                return [URLQueryItem(name: "path", value: path.string)]
            case .write(let path, let offset):
                return [URLQueryItem(name: "path", value: path.string),
                        URLQueryItem(name: "offset", value: String(offset))]
            case .checksum(let path, let algorithm):
                return [URLQueryItem(name: "path", value: path.string),
                        URLQueryItem(name: "algorithm", value: algorithm.rawValue)]
            default:
                return []
            }
        }
    }

    // MARK: - Payloads

    public struct DeviceInfo: Codable, Sendable {
        public var name: String
        public var model: String
        public var manufacturer: String
        public var androidRelease: String
        public var serial: String?
        public var apiVersion: String
        /// False until the user grants all-files access on the phone.
        public var hasFullFilesystemAccess: Bool
    }

    public struct Entry: Codable, Sendable {
        public var path: String
        public var size: Int64
        /// Seconds since the epoch; absent when the device does not know.
        public var modified: Int64?
        public var kind: String

        public var remoteFile: RemoteFile {
            RemoteFile(
                path: RemotePath(path),
                size: size,
                modified: modified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                kind: RemoteFile.Kind(rawValue: kind) ?? .file
            )
        }
    }

    public struct VolumeInfo: Codable, Sendable {
        public var id: String
        public var name: String
        public var path: String
        public var totalBytes: Int64
        public var freeBytes: Int64
        public var removable: Bool
        public var filesystem: String
    }

    public struct FreeSpaceInfo: Codable, Sendable {
        public var totalBytes: Int64
        public var freeBytes: Int64
    }

    public struct ChecksumInfo: Codable, Sendable {
        public var algorithm: String
        public var value: String
    }

    public struct PathRequest: Codable, Sendable {
        public var path: String
        public var recursive: Bool?
        public init(path: String, recursive: Bool? = nil) {
            self.path = path
            self.recursive = recursive
        }
    }

    public struct MoveRequest: Codable, Sendable {
        public var from: String
        public var to: String
        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public struct TouchRequest: Codable, Sendable {
        public var path: String
        public var epochSeconds: Int64
        public init(path: String, epochSeconds: Int64) {
            self.path = path
            self.epochSeconds = epochSeconds
        }
    }

    public struct PairRequest: Codable, Sendable {
        public var code: String
        public var clientName: String
        public init(code: String, clientName: String) {
            self.code = code
            self.clientName = clientName
        }
    }

    public struct PairResponse: Codable, Sendable {
        public var token: String
        public var deviceName: String
        /// SHA-256 of the server's certificate, pinned from here on.
        public var certificateFingerprint: String
    }

    public struct ErrorResponse: Codable, Sendable {
        public var error: String
        public var detail: String?
    }
}
