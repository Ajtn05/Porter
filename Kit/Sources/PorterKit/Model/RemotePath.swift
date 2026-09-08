import Foundation

/// A POSIX-style absolute path on a connected device.
///
/// Device paths are always `/`-separated and are *not* the same namespace as
/// macOS file URLs, so they get their own type. Mixing the two up is how you end
/// up writing `/storage/emulated/0` into someone's home directory.
public struct RemotePath: Hashable, Sendable, Codable, CustomStringConvertible {
    public private(set) var components: [String]

    public init(components: [String]) {
        self.components = components.filter { !$0.isEmpty && $0 != "." }
    }

    public init(_ string: String) {
        self.init(components: string.split(separator: "/").map(String.init))
    }

    public static let root = RemotePath(components: [])

    public var string: String { "/" + components.joined(separator: "/") }
    public var description: String { string }

    public var name: String { components.last ?? "/" }

    public var isRoot: Bool { components.isEmpty }

    public var parent: RemotePath? {
        guard !components.isEmpty else { return nil }
        return RemotePath(components: Array(components.dropLast()))
    }

    public func appending(_ component: String) -> RemotePath {
        RemotePath(components: components + [component])
    }

    public func appending(path: RemotePath) -> RemotePath {
        RemotePath(components: components + path.components)
    }

    /// Every ancestor from the root down to and including `self`, for breadcrumbs.
    public var breadcrumbs: [RemotePath] {
        var result: [RemotePath] = [.root]
        var acc: [String] = []
        for component in components {
            acc.append(component)
            result.append(RemotePath(components: acc))
        }
        return result
    }

    public func isDescendant(of other: RemotePath) -> Bool {
        guard components.count > other.components.count else { return false }
        return Array(components.prefix(other.components.count)) == other.components
    }

    /// The portion of `self` below `base`, or nil if `self` is not under `base`.
    public func relative(to base: RemotePath) -> RemotePath? {
        guard components.count >= base.components.count,
              Array(components.prefix(base.components.count)) == base.components else { return nil }
        return RemotePath(components: Array(components.dropFirst(base.components.count)))
    }

    /// Single-quoted for safe interpolation into an `adb shell` command line.
    ///
    /// Android's shell is POSIX-ish; single quotes suppress every expansion, and
    /// an embedded quote is closed, escaped, and reopened.
    public var shellQuoted: String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension String {
    /// Single-quoted for safe interpolation into an `adb shell` command line.
    public var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
