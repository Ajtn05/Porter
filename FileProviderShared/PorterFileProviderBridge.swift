import CryptoKit
import FileProvider
import Foundation

/// The one app group shared by Porter and its File Provider extension.
///
/// The extension uses this group for an opaque domain mapping and its request
/// queue. Pairing secrets remain in Keychain.
enum PorterFileProviderConfiguration {
    static let documentGroup = "group.app.porter.fileprovider"
    static let deviceKeyPrefix = "file-provider.device."
    static let bridgeDirectory = "FileProviderBridge"
}

/// Stores device identities outside Finder-visible item identifiers. Finder can
/// record item identifiers in logs, so remote paths and Android serials never
/// appear in those identifiers.
enum PorterFileProviderDomainRegistry {
    static func identifier(for deviceID: String) -> String {
        let digest = SHA256.hash(data: Data(deviceID.utf8))
        return "porter-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func register(deviceID: String) -> String {
        let identifier = identifier(for: deviceID)
        preferences?.set(deviceID, forKey: PorterFileProviderConfiguration.deviceKeyPrefix + identifier)
        return identifier
    }

    static func deviceID(for identifier: String) -> String? {
        preferences?.string(forKey: PorterFileProviderConfiguration.deviceKeyPrefix + identifier)
    }

    private static var preferences: UserDefaults? {
        UserDefaults(suiteName: PorterFileProviderConfiguration.documentGroup)
    }
}

enum PorterFileProviderItemIdentifier {
    static func item(for path: String) -> NSFileProviderItemIdentifier {
        let digest = SHA256.hash(data: Data(path.utf8))
        let identifier = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return NSFileProviderItemIdentifier("porter-item-\(identifier)")
    }
}

/// Coordinates JSON request/reply files in the File Provider document group.
/// Anonymous XPC listener endpoints cannot be persisted between the app and
/// extension processes; this group is available to exactly those signed targets.
enum PorterFileProviderFileBridge {
    static func directories() -> (requests: URL, responses: URL, downloads: URL,
                                  cancellations: URL, progress: URL)? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PorterFileProviderConfiguration.documentGroup
        ) else {
            return nil
        }
        let root = container.appendingPathComponent(
            PorterFileProviderConfiguration.bridgeDirectory,
            isDirectory: true
        )
        let requests = root.appendingPathComponent("Requests", isDirectory: true)
        let responses = root.appendingPathComponent("Responses", isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let cancellations = root.appendingPathComponent("Cancellations", isDirectory: true)
        let progress = root.appendingPathComponent("Progress", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cancellations, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: progress, withIntermediateDirectories: true)
            return (requests, responses, downloads, cancellations, progress)
        } catch {
            return nil
        }
    }
}

/// File Provider callback types predate Swift concurrency annotations, but the
/// framework permits completing them from the asynchronous task that follows.
struct PorterUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

struct PorterFileProviderBridgeReply: Codable, Sendable {
    var responseData: Data?
    var errorDescription: String?

    init(responseData: Data? = nil, errorDescription: String? = nil) {
        self.responseData = responseData
        self.errorDescription = errorDescription
    }
}

enum PorterFileProviderRequest: Codable, Sendable {
    case volumes(domainIdentifier: String)
    case list(domainIdentifier: String, path: String)
    case item(domainIdentifier: String, path: String)
    case download(domainIdentifier: String, path: String)
}

enum PorterFileProviderResponse: Codable, Sendable {
    case items([PorterFileProviderRecord])
    case item(PorterFileProviderRecord?)
    case downloadedFile(name: String, size: Int64)
}

/// Metadata carried between the trusted host and the File Provider extension.
struct PorterFileProviderRecord: Codable, Sendable, Hashable {
    var path: String
    var name: String
    var parentPath: String?
    var size: Int64
    var modified: Date?
    var isDirectory: Bool

    init(path: String, name: String, parentPath: String?, size: Int64,
         modified: Date?, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.parentPath = parentPath
        self.size = size
        self.modified = modified
        self.isDirectory = isDirectory
    }
}

enum PorterFileProviderBridgeError: LocalizedError {
    case hostUnavailable
    case invalidResponse
    case hostFailed(String)

    var errorDescription: String? {
        switch self {
        case .hostUnavailable:
            return "Open Porter and reconnect the phone, then try again."
        case .invalidResponse:
            return "Porter returned an invalid File Provider response."
        case .hostFailed(let message):
            return message
        }
    }
}
