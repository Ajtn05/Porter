import Foundation

/// Turns byte-count updates into a displayable transfer rate and ETA.
///
/// Uses an exponentially weighted moving average. A raw instantaneous rate
/// jitters too much to read, and a cumulative average lags for the first minute
/// of any transfer that changes pace; the EWMA is stable enough to display at
/// 10 Hz and still reacts within a couple of seconds.
public struct ThroughputMeter: Sendable {
    /// Weight given to the newest sample. At 0.25 the average settles in about
    /// three samples.
    private let smoothing: Double
    private var lastTimestamp: TimeInterval?
    private var smoothedRate: Double = 0
    private var samples: Int = 0

    public private(set) var totalBytes: Int64 = 0

    public init(smoothing: Double = 0.25) {
        self.smoothing = smoothing
    }

    /// Records the bytes observed since the previous call.
    public mutating func record(bytes: Int64, at timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        totalBytes += bytes
        defer { lastTimestamp = timestamp }
        guard let last = lastTimestamp else { return }
        let elapsed = timestamp - last
        // Sub-millisecond gaps yield wildly inflated instantaneous rates.
        guard elapsed > 0.001 else { return }
        let instantaneous = Double(bytes) / elapsed
        if samples == 0 {
            smoothedRate = instantaneous
        } else {
            smoothedRate += smoothing * (instantaneous - smoothedRate)
        }
        samples += 1
    }

    /// Marks a gap in the transfer, such as a pause or a reconnect, so the
    /// resumed rate is not computed against idle wall-clock time.
    public mutating func suspend() {
        lastTimestamp = nil
    }

    public var bytesPerSecond: Double {
        samples > 0 ? Swift.max(0, smoothedRate) : 0
    }

    /// Seconds remaining, or nil when there are too few samples to estimate.
    /// Callers render nil as a placeholder rather than a fabricated figure.
    public func estimatedTimeRemaining(totalExpectedBytes: Int64) -> TimeInterval? {
        guard samples >= 2, bytesPerSecond > 0 else { return nil }
        let remaining = totalExpectedBytes - totalBytes
        guard remaining > 0 else { return 0 }
        return Double(remaining) / bytesPerSecond
    }
}
