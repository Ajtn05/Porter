import Foundation

public struct StorageVolume: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    /// The name the device gave us. Not unique: two SD cards can both be "SD card".
    public var rawName: String
    public var rootPath: RemotePath
    public var totalBytes: Int64?
    public var freeBytes: Int64?
    public var isRemovable: Bool
    /// The underlying filesystem, when we can determine it. FAT32 means a hard
    /// 4 GiB per-file ceiling that we must check before starting a copy.
    public var filesystem: Filesystem
    /// MTP devices routinely report free space that is stale, rounded, or simply
    /// wrong. When this is false the engine probes before a large write instead
    /// of trusting `freeBytes`.
    public var freeSpaceIsTrustworthy: Bool
    /// Assigned by `StorageVolume.disambiguate` when names collide.
    public var nameSuffix: String?

    public init(id: String, rawName: String, rootPath: RemotePath, totalBytes: Int64? = nil,
                freeBytes: Int64? = nil, isRemovable: Bool = false,
                filesystem: Filesystem = .unknown, freeSpaceIsTrustworthy: Bool = true,
                nameSuffix: String? = nil) {
        self.id = id
        self.rawName = rawName
        self.rootPath = rootPath
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isRemovable = isRemovable
        self.filesystem = filesystem
        self.freeSpaceIsTrustworthy = freeSpaceIsTrustworthy
        self.nameSuffix = nameSuffix
    }

    /// What the sidebar shows. Includes the disambiguating suffix when one was needed.
    public var displayName: String {
        guard let nameSuffix else { return rawName }
        return "\(rawName) (\(nameSuffix))"
    }

    public enum Filesystem: String, Sendable, Codable {
        case ext4
        case f2fs
        case fat32
        case exfat
        case sdcardfs
        case fuse
        case unknown

        /// FAT32 cannot store a file of 4 GiB or more, full stop.
        public var maximumFileSize: Int64? {
            switch self {
            case .fat32: return 4 * 1024 * 1024 * 1024 - 1
            default: return nil
            }
        }

        public var displayName: String {
            switch self {
            case .fat32: return "FAT32"
            case .exfat: return "exFAT"
            case .ext4: return "ext4"
            case .f2fs: return "F2FS"
            case .sdcardfs: return "sdcardfs"
            case .fuse: return "FUSE"
            case .unknown: return "Unknown"
            }
        }
    }
}

extension Array where Element == StorageVolume {
    /// Give every volume a unique display name.
    ///
    /// Two microSD cards, or an internal volume and a card that both call
    /// themselves "SD card", must not be indistinguishable in the sidebar. We
    /// prefer a human-meaningful suffix (capacity) and fall back to the mount
    /// path, which is always unique.
    public func disambiguated() -> [StorageVolume] {
        var countsByName: [String: Int] = [:]
        for volume in self { countsByName[volume.rawName, default: 0] += 1 }

        var usedNames: Set<String> = []
        return map { volume in
            guard (countsByName[volume.rawName] ?? 0) > 1 else { return volume }
            var copy = volume
            let capacity = volume.totalBytes.map { ByteFormat.short($0) }
            // Capacity only disambiguates if it is actually distinct.
            let sameNameCapacities = self.filter { $0.rawName == volume.rawName }
                .compactMap { $0.totalBytes.map { ByteFormat.short($0) } }
            if let capacity, Set(sameNameCapacities).count == sameNameCapacities.count,
               sameNameCapacities.count == countsByName[volume.rawName],
               !usedNames.contains("\(volume.rawName) (\(capacity))") {
                copy.nameSuffix = capacity
            } else {
                copy.nameSuffix = volume.rootPath.string
            }
            usedNames.insert(copy.displayName)
            return copy
        }
    }
}

/// The result of asking a device how much room is left, plus how much we believe it.
public struct FreeSpaceReport: Hashable, Sendable {
    public var reportedFreeBytes: Int64?
    public var totalBytes: Int64?
    public var isTrustworthy: Bool
    /// Set when we actually wrote a probe file to check.
    public var verifiedFreeBytes: Int64?

    public init(reportedFreeBytes: Int64?, totalBytes: Int64?, isTrustworthy: Bool, verifiedFreeBytes: Int64? = nil) {
        self.reportedFreeBytes = reportedFreeBytes
        self.totalBytes = totalBytes
        self.isTrustworthy = isTrustworthy
        self.verifiedFreeBytes = verifiedFreeBytes
    }

    public var bestEstimate: Int64? { verifiedFreeBytes ?? reportedFreeBytes }
}
