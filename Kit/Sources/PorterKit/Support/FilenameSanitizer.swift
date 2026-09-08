import Foundation

/// Reconciles the naming rules of the source and destination filesystems, and
/// reports every change it makes.
///
/// Android's ext4/F2FS volumes allow any byte except `/` and NUL. macOS allows
/// almost as much, but `:` was historically the path separator and Finder still
/// renders it as `/`, so `a:b` on the phone appears as `a/b` on the Mac. FAT32
/// and exFAT cards are stricter again.
///
/// Names are never altered silently: each change is reported back to the caller
/// so it can be surfaced.
public struct FilenameSanitizer: Sendable {
    public enum Destination: Sendable {
        case macOS
        /// Android internal storage, or any other ext4/F2FS volume.
        case androidPOSIX
        /// FAT32/exFAT removable storage, which is considerably stricter.
        case androidFAT
    }

    public struct Change: Hashable, Sendable {
        public let original: String
        public let sanitized: String
        public let reason: String
    }

    public let destination: Destination
    public init(destination: Destination) {
        self.destination = destination
    }

    private static let fatIllegal: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
    /// Reserved DOS device names, still rejected by some exFAT drivers.
    private static let fatReserved: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    ]

    /// Returns the name to use, plus a `Change` when it differs from the input.
    public func sanitize(_ name: String) -> (name: String, change: Change?) {
        var result = name
        var reasons: [String] = []

        // NUL and the path separator are illegal on every destination.
        if result.contains("\0") {
            result = result.replacingOccurrences(of: "\0", with: "")
            reasons.append("removed a null byte")
        }

        switch destination {
        case .macOS:
            // Finder renders ":" as "/". Substitute a visually similar
            // character rather than dropping it, to keep the name readable.
            if result.contains(":") {
                result = result.replacingOccurrences(of: ":", with: "\u{2236}")
                reasons.append("replaced \u{201C}:\u{201D}, which Finder shows as \u{201C}/\u{201D}")
            }
        case .androidPOSIX:
            if result.contains("/") {
                result = result.replacingOccurrences(of: "/", with: "_")
                reasons.append("replaced \u{201C}/\u{201D}, which cannot appear in an Android filename")
            }
        case .androidFAT:
            let stripped = String(result.map { Self.fatIllegal.contains($0) ? "_" : $0 })
            if stripped != result {
                result = stripped
                reasons.append("replaced characters the card\u{2019}s FAT filesystem rejects")
            }
            // FAT cannot store a name ending in a space or a period.
            let trimmed = trimTrailingDotsAndSpaces(result)
            if trimmed != result {
                result = trimmed
                reasons.append("removed a trailing space or period, which FAT cannot store")
            }
            let stem = result.split(separator: ".").first.map(String.init) ?? result
            if Self.fatReserved.contains(stem.uppercased()) {
                result = "_" + result
                reasons.append("\u{201C}\(stem)\u{201D} is a reserved name on FAT volumes")
            }
        }

        // Both macOS and ext4 cap a path component at 255 bytes of UTF-8.
        // Truncate on a character boundary and keep the extension.
        if result.utf8.count > 255 {
            result = truncateToUTF8Bytes(result, limit: 255)
            reasons.append("shortened a name longer than 255 bytes")
        }

        if result.isEmpty {
            result = "untitled"
            reasons.append("the name was empty after sanitizing")
        }

        guard result != name else { return (name, nil) }
        return (result, Change(original: name, sanitized: result, reason: reasons.joined(separator: "; ")))
    }

    private func trimTrailingDotsAndSpaces(_ value: String) -> String {
        var result = value
        while let last = result.last, last == "." || last == " " {
            result.removeLast()
        }
        return result
    }

    private func truncateToUTF8Bytes(_ value: String, limit: Int) -> String {
        // Keep the extension so the file still opens in the right app.
        let ext = (value as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        let suffixBytes = suffix.utf8.count
        let budget = Swift.max(1, limit - suffixBytes)

        var stem = ext.isEmpty ? value : String(value.dropLast(suffix.count))
        while stem.utf8.count > budget, !stem.isEmpty {
            stem.removeLast()
        }
        return stem + suffix
    }

    /// Sanitizes every component of a relative path, collecting all changes.
    public func sanitize(components: [String]) -> (components: [String], changes: [Change]) {
        var out: [String] = []
        var changes: [Change] = []
        for component in components {
            let (name, change) = sanitize(component)
            out.append(name)
            if let change { changes.append(change) }
        }
        return (out, changes)
    }
}
