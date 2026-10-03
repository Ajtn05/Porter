import Foundation

/// Parsers for the output `adb` and Android's toybox emit.
///
/// Kept separate from the transport so they can be tested against captured
/// device output with no phone attached. The formats differ subtly between
/// Android versions and vendor ROMs, so the captured cases matter.
public enum ADBParsing {

    // MARK: - adb devices -l

    public struct DeviceListing: Hashable, Sendable {
        public var serial: String
        public var state: String
        public var properties: [String: String]

        public var readiness: DeviceReadiness {
            switch state {
            case "device": return .ready
            case "unauthorized": return .unauthorized
            case "offline", "recovery", "sideload", "bootloader": return .offline
            default: return .offline
            }
        }

        public var isNetworkAddress: Bool {
            // ADB network endpoints use "host:port" as the serial. Porter
            // only lists devices attached through USB.
            serial.contains(":") && serial.split(separator: ":").count == 2
        }

        public var model: String? {
            properties["model"].map { $0.replacingOccurrences(of: "_", with: " ") }
        }
    }

    /// Parses `adb devices -l`, ignoring the header and the messages adb prints
    /// when it starts its server.
    public static func parseDeviceList(_ output: String) -> [DeviceListing] {
        var results: [DeviceListing] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("List of devices") { continue }
            if line.hasPrefix("*") { continue }              // "* daemon started successfully"
            if line.hasPrefix("adb server") { continue }

            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2 else { continue }
            let serial = fields[0]
            let state = fields[1]

            var properties: [String: String] = [:]
            for field in fields.dropFirst(2) {
                let parts = field.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { properties[parts[0]] = parts[1] }
            }
            results.append(DeviceListing(serial: serial, state: state, properties: properties))
        }
        return results
    }

    // MARK: - stat -c '%f|%s|%Y|%n'

    /// Parses the output of
    /// `find DIR -maxdepth 1 -mindepth 1 -exec stat -c '%f|%s|%Y|%n' {} +`.
    ///
    /// Filenames on Android may legally contain newlines, which would split one
    /// entry across two lines. A line not starting with the
    /// `hex|digits|digits|` prefix is therefore treated as a continuation of
    /// the previous filename rather than as a new record.
    public static func parseStatRecords(_ output: String) -> [RemoteFile] {
        var results: [RemoteFile] = []
        var pending: (mode: UInt32, size: Int64, mtime: Int64, name: String)?

        func flush() {
            guard let record = pending else { return }
            pending = nil
            let path = RemotePath(record.name)
            guard !path.components.isEmpty else { return }
            results.append(RemoteFile(
                path: path,
                size: record.size,
                modified: record.mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(record.mtime)) : nil,
                kind: kind(fromRawMode: record.mode),
                posixPermissions: UInt16(record.mode & 0o7777)
            ))
        }

        // Strip exactly one trailing newline. Left in place, it splits into an
        // empty final component, which the continuation rule below would append
        // to the last filename as a stray "\n".
        var text = output
        if text.hasSuffix("\n") { text.removeLast() }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if let record = parseStatLine(text) {
                flush()
                pending = record
            } else if pending != nil {
                // Continuation of a filename containing a newline.
                pending?.name += "\n" + text
            }
        }
        flush()
        return results
    }

    private static func parseStatLine(_ line: String) -> (mode: UInt32, size: Int64, mtime: Int64, name: String)? {
        let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4,
              let mode = UInt32(parts[0], radix: 16),
              let size = Int64(parts[1]),
              let mtime = Int64(parts[2]),
              parts[3].hasPrefix("/") else { return nil }
        return (mode, size, mtime, parts[3])
    }

    /// S_IFMT decoding of the raw mode `stat -c %f` reports in hex.
    public static func kind(fromRawMode mode: UInt32) -> RemoteFile.Kind {
        switch mode & 0xF000 {
        case 0x8000: return .file
        case 0x4000: return .directory
        case 0xA000: return .symlink
        default: return .other
        }
    }

    // MARK: - ls -la fallback

    private static let lsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// Fallback parser for toybox `ls -la`, used on ROMs without `stat`.
    ///
    /// Format: `mode links owner group size YYYY-MM-DD HH:MM name`. The name is
    /// everything after the time field, so spaces in names survive. Timestamps
    /// are only minute-granular, which is why this is not the primary parser:
    /// they are too coarse to preserve mtimes.
    public static func parseListing(_ output: String, in directory: RemotePath) -> [RemoteFile] {
        var results: [RemoteFile] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("total ") { continue }
            let fields = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true).map(String.init)
            guard fields.count == 8 else { continue }

            let modeString = fields[0]
            guard modeString.count >= 10 else { continue }
            let size = Int64(fields[4]) ?? 0
            let date = lsDateFormatter.date(from: "\(fields[5]) \(fields[6])")

            var name = fields[7]
            var symlinkTarget: String?
            if modeString.hasPrefix("l"), let range = name.range(of: " -> ") {
                symlinkTarget = String(name[range.upperBound...])
                name = String(name[name.startIndex..<range.lowerBound])
            }
            if name == "." || name == ".." { continue }

            let kind: RemoteFile.Kind
            switch modeString.first {
            case "d": kind = .directory
            case "l": kind = .symlink
            case "-": kind = .file
            default: kind = .other
            }

            results.append(RemoteFile(
                path: directory.appending(name),
                size: size,
                modified: date,
                kind: kind,
                posixPermissions: permissions(fromModeString: modeString),
                symlinkTarget: symlinkTarget
            ))
        }
        return results
    }

    static func permissions(fromModeString mode: String) -> UInt16? {
        let characters = Array(mode.dropFirst())
        guard characters.count >= 9 else { return nil }
        var bits: UInt16 = 0
        for (index, character) in characters.prefix(9).enumerated() {
            if character != "-" && character != "S" && character != "T" {
                bits |= UInt16(1 << (8 - index))
            }
        }
        return bits
    }

    // MARK: - df

    public struct DiskFree: Hashable, Sendable {
        public var totalBytes: Int64
        public var availableBytes: Int64
        public var mountPoint: String
    }

    /// Parses `df -k PATH`, taking the last data row: toybox wraps long device
    /// names onto a second line, leaving the numbers on the wrap.
    public static func parseDiskFree(_ output: String) -> DiskFree? {
        let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Filesystem") }
        guard let line = lines.last else { return nil }

        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // Expected: Filesystem 1K-blocks Used Available Use% Mounted-on. A
        // wrapped device name leaves the numbers alone on the next line with no
        // filesystem column, so count indices from the end, which holds either
        // way.
        guard fields.count >= 5,
              let blocks = Int64(fields[fields.count - 5]),
              let available = Int64(fields[fields.count - 3]) else { return nil }
        return DiskFree(
            totalBytes: blocks * 1024,
            availableBytes: available * 1024,
            mountPoint: fields[fields.count - 1]
        )
    }

    /// Maps `stat -f -c %T` output onto a known filesystem.
    ///
    /// GNU coreutils prints a name here, while Android's toybox prints the raw
    /// superblock magic in hex: a Galaxy S22 on Android 16 answers
    /// `0x65735546`, not `fuse`. Both forms are accepted.
    public static func filesystem(fromStatType type: String) -> StorageVolume.Filesystem {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if trimmed.hasPrefix("0x"), let magic = UInt32(trimmed.dropFirst(2), radix: 16) {
            return filesystem(fromSuperblockMagic: magic)
        }
        switch trimmed {
        case "ext4", "ext2/ext3": return .ext4
        case "f2fs": return .f2fs
        case "msdos", "fat", "vfat", "fat32": return .fat32
        case "exfat": return .exfat
        case "sdcardfs": return .sdcardfs
        case "fuseblk", "fuse", "fusectl": return .fuse
        default: return .unknown
        }
    }

    /// Superblock magic numbers, as defined in the kernel's `magic.h`.
    public static func filesystem(fromSuperblockMagic magic: UInt32) -> StorageVolume.Filesystem {
        switch magic {
        case 0xEF53: return .ext4              // shared by ext2, ext3 and ext4
        case 0xF2F5_2010: return .f2fs
        case 0x6573_5546: return .fuse         // "FUse", Android's scoped-storage layer
        case 0x4D44: return .fat32             // MSDOS_SUPER_MAGIC, also used by vfat
        case 0x2011_BAB0: return .exfat
        case 0x5DCA_2DF5: return .sdcardfs
        default: return .unknown
        }
    }

    /// Reads the filesystem backing a mount point out of `mount` output.
    ///
    /// Android presents user storage through a FUSE layer, so querying the
    /// filesystem directly reports "fuse" rather than what lies underneath.
    /// Only `mount` names the backing filesystem, which is what determines
    /// whether a file over 4 GiB will fit.
    public static func backingFilesystem(fromMountOutput output: String, forPath path: String) -> StorageVolume.Filesystem {
        var best: (length: Int, filesystem: StorageVolume.Filesystem)?

        for line in output.split(separator: "\n") {
            // Format: <device> on <mount-point> type <fstype> (<options>)
            let fields = line.split(separator: " ").map(String.init)
            guard let onIndex = fields.firstIndex(of: "on"),
                  let typeIndex = fields.firstIndex(of: "type"),
                  typeIndex + 1 < fields.count,
                  onIndex + 1 < typeIndex else { continue }

            let mountPoint = fields[(onIndex + 1)..<typeIndex].joined(separator: " ")
            let parsed = filesystem(fromStatType: fields[typeIndex + 1])
            guard parsed != .unknown, parsed != .fuse else { continue }
            guard path == mountPoint || path.hasPrefix(mountPoint + "/") else { continue }
            // Longest matching mount point wins, as the kernel resolves it.
            if best == nil || mountPoint.count > best!.length {
                best = (mountPoint.count, parsed)
            }
        }
        return best?.filesystem ?? .unknown
    }

    // MARK: - getprop

    /// Parses the `[key]: [value]` form `getprop` prints with no arguments.
    public static func parseProperties(_ output: String) -> [String: String] {
        var properties: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let separator = line.range(of: "]: [") else { continue }
            let key = line[line.startIndex..<separator.lowerBound].dropFirst()
            let value = line[separator.upperBound...].dropLast()
            properties[String(key)] = String(value)
        }
        return properties
    }
}
