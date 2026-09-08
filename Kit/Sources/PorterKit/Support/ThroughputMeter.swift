import Foundation

/// Turns a stream of "n more bytes arrived" events into a rate and an ETA that
/// a human can act on.
///
/// A raw instantaneous rate jitters far too much to read, and a cumulative
/// average is wrong for the whole first minute of any transfer that changes
/// pace. This uses an exponentially weighted moving average over a fixed sample
/// window, which is stable enough to display at 10 Hz and still reacts within a
/// couple of seconds when the phone throttles or the cable is knocked.
public struct ThroughputMeter: Sendable {
    /// Weight given to the newest sample. 0.25 settles in roughly 3 samples.
    private let smoothing: Double
    private var lastTimestamp: TimeInterval?
    private var smoothedRate: Double = 0
    private var samples: Int = 0

    public private(set) var totalBytes: Int64 = 0

    public init(smoothing: Double = 0.25) {
        self.smoothing = smoothing
    }

    /// Feed in bytes observed since the previous call.
    public mutating func record(bytes: Int64, at timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        totalBytes += bytes
        defer { lastTimestamp = timestamp }
        guard let last = lastTimestamp else { return }
        let elapsed = timestamp - last
        // Ignore sub-millisecond gaps; they produce absurd instantaneous rates.
        guard elapsed > 0.001 else { return }
        let instantaneous = Double(bytes) / elapsed
        if samples == 0 {
            smoothedRate = instantaneous
        } else {
            smoothedRate += smoothing * (instantaneous - smoothedRate)
        }
        samples += 1
    }

    /// Marks a gap in the transfer (a pause, a reconnect) so the resumed rate is
    /// not computed against wall-clock time spent doing nothing.
    public mutating func suspend() {
        lastTimestamp = nil
    }

    public var bytesPerSecond: Double {
        samples > 0 ? Swift.max(0, smoothedRate) : 0
    }

    /// Seconds remaining, or nil when we do not have enough signal to guess.
    /// Returning nil is the honest answer; the UI shows "—" rather than a lie.
    public func estimatedTimeRemaining(totalExpectedBytes: Int64) -> TimeInterval? {
        guard samples >= 2, bytesPerSecond > 0 else { return nil }
        let remaining = totalExpectedBytes - totalBytes
        guard remaining > 0 else { return 0 }
        return Double(remaining) / bytesPerSecond
    }
}
