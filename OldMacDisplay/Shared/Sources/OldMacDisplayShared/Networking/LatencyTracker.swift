import Foundation

/// Rolling round-trip-time statistics from the Ping/Pong exchange.
///
/// Uses an exponentially weighted moving average so the displayed figure is
/// stable enough to read but still reacts within a second or so.
public struct LatencyTracker: Equatable {
    private let smoothing: Double
    public private(set) var smoothedRTT: Double?
    public private(set) var lastRTT: Double?
    public private(set) var minRTT: Double?
    public private(set) var maxRTT: Double?
    public private(set) var sampleCount: Int = 0

    public init(smoothing: Double = 0.2) {
        self.smoothing = smoothing
    }

    /// Records a sample, in seconds.
    public mutating func record(rtt: Double) {
        guard rtt.isFinite, rtt >= 0 else { return }
        lastRTT = rtt
        sampleCount += 1
        minRTT = minRTT.map { Swift.min($0, rtt) } ?? rtt
        maxRTT = maxRTT.map { Swift.max($0, rtt) } ?? rtt
        if let current = smoothedRTT {
            smoothedRTT = current + smoothing * (rtt - current)
        } else {
            smoothedRTT = rtt
        }
    }

    /// Smoothed RTT in milliseconds, for display.
    public var smoothedMilliseconds: Double? {
        smoothedRTT.map { $0 * 1000.0 }
    }

    public mutating func reset() {
        self = LatencyTracker(smoothing: smoothing)
    }
}
