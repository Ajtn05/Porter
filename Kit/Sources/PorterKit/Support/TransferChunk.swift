import Foundation

public enum TransferChunk {
    /// The alignment unit for every resumable transfer.
    ///
    /// Resume offsets are always a multiple of this, so a ranged read can be
    /// expressed as a plain `dd skip=<blocks>` count and never needs
    /// `iflag=skip_bytes`, a GNU extension older toybox builds lack. The size
    /// also keeps per-chunk overhead low while leaving cancellation prompt.
    public static let blockSize: Int64 = 1024 * 1024

    /// Rounds an offset down to a block boundary.
    public static func alignedDown(_ offset: Int64) -> Int64 {
        offset - (offset % blockSize)
    }
}
