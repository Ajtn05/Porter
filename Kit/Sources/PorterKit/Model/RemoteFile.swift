import Foundation

public struct RemoteFile: Identifiable, Hashable, Sendable, Codable {
    public var path: RemotePath
    public var size: Int64
    public var modified: Date?
    public var kind: Kind
    public var posixPermissions: UInt16?
    /// Present when the device gave us a link target we could not resolve.
    public var symlinkTarget: String?

    public var id: String { path.string }
    public var name: String { path.name }
    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }

    public enum Kind: String, Sendable, Codable {
        case file
        case directory
        case symlink
        case other
    }

    public init(path: RemotePath, size: Int64 = 0, modified: Date? = nil, kind: Kind = .file,
                posixPermissions: UInt16? = nil, symlinkTarget: String? = nil) {
        self.path = path
        self.size = size
        self.modified = modified
        self.kind = kind
        self.posixPermissions = posixPermissions
        self.symlinkTarget = symlinkTarget
    }

    public var fileExtension: String {
        let parts = name.split(separator: ".")
        guard parts.count > 1, let last = parts.last else { return "" }
        return String(last).lowercased()
    }
}

/// A half-open byte range `[lowerBound, upperBound)` within a file.
public struct ByteRange: Hashable, Sendable, Codable {
    public var offset: Int64
    public var length: Int64?

    public init(offset: Int64 = 0, length: Int64? = nil) {
        self.offset = offset
        self.length = length
    }

    public static let whole = ByteRange()

    public var isWholeFile: Bool { offset == 0 && length == nil }

    public func upperBound(fileSize: Int64) -> Int64 {
        guard let length else { return fileSize }
        return Swift.min(offset + length, fileSize)
    }
}
