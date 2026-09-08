import Foundation

public enum TransferChunk {
    /// The unit every resumable transfer is aligned to.
    ///
    /// Resume offsets are always a multiple of this, which means a ranged read
    /// can be expressed as a plain `dd skip=<blocks>` block count and never
    /// needs `iflag=skip_bytes` — a GNU extension that older toybox builds on
    /// Android do not have. It is also a reasonable read size: large enough that
    /// per-chunk overhead disappears, small enough that cancelling is prompt.
    public static let blockSize: Int64 = 1024 * 1024

    /// Rounds an offset down to a block boundary.
    public static func alignedDown(_ offset: Int64) -> Int64 {
        offset - (offset % blockSize)
    }
}
