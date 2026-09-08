import Foundation

/// What to do when the destination already has a file with this name.
public enum ConflictResolution: String, Sendable, Codable, CaseIterable, Identifiable {
    case skip
    case replace
    case keepBoth
    /// Resume/overwrite only when the source is newer. Used by watched-folder sync.
    case replaceIfNewer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .skip: return "Skip"
        case .replace: return "Replace"
        case .keepBoth: return "Keep Both"
        case .replaceIfNewer: return "Replace if Newer"
        }
    }
}

/// A decision plus whether the user asked to apply it to the rest of this batch.
public struct ConflictDecision: Hashable, Sendable, Codable {
    public var resolution: ConflictResolution
    public var applyToAll: Bool

    public init(resolution: ConflictResolution, applyToAll: Bool = false) {
        self.resolution = resolution
        self.applyToAll = applyToAll
    }
}

/// The facts the user needs in order to choose. Deliberately includes both
/// sides' size and date: "Replace" is a destructive answer and the dialog should
/// make it obvious which copy is which.
public struct ConflictContext: Hashable, Sendable {
    public var name: String
    public var destinationPath: String
    public var sourceSize: Int64
    public var destinationSize: Int64
    public var sourceModified: Date?
    public var destinationModified: Date?

    public init(name: String, destinationPath: String, sourceSize: Int64, destinationSize: Int64,
                sourceModified: Date?, destinationModified: Date?) {
        self.name = name
        self.destinationPath = destinationPath
        self.sourceSize = sourceSize
        self.destinationSize = destinationSize
        self.sourceModified = sourceModified
        self.destinationModified = destinationModified
    }

    public var sourceIsNewer: Bool {
        guard let sourceModified, let destinationModified else { return false }
        // One-second slack: FAT stores mtimes at 2s granularity, and MTP rounds.
        return sourceModified.timeIntervalSince(destinationModified) > 1
    }
}

public enum ConflictNaming {
    /// macOS-style "keep both": `photo.jpg` -> `photo 2.jpg` -> `photo 3.jpg`.
    /// Matches Finder so the result is not surprising next to a Finder copy.
    public static func uniqueName(for name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let nsName = name as NSString
        let ext = nsName.pathExtension
        let stem = ext.isEmpty ? name : nsName.deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext

        // If the name already ends in " N", continue that sequence.
        var base = stem
        var start = 2
        if let range = stem.range(of: #" (\d+)$"#, options: .regularExpression),
           let n = Int(stem[range].trimmingCharacters(in: .whitespaces)) {
            base = String(stem[stem.startIndex..<range.lowerBound])
            start = n + 1
        }

        var index = start
        while true {
            let candidate = "\(base) \(index)\(suffix)"
            if !existing.contains(candidate) { return candidate }
            index += 1
            // Defensive: a directory with 10k same-named files is pathological,
            // but an unbounded loop here would hang the transfer thread.
            if index > 10_000 { return "\(base) \(UUID().uuidString.prefix(8))\(suffix)" }
        }
    }
}
