import Foundation

public enum ByteFormat {
    /// Finder-style sizes: decimal units, because that is what macOS shows and a
    /// mismatch here reads as a bug to anyone comparing the two windows.
    public static func short(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return short(Int64(bytesPerSecond)) + "/s"
    }

    /// A compact duration: "12s", "4m 03s", "1h 22m".
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 {
            return String(format: "%dm %02ds", total / 60, total % 60)
        }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }
}
