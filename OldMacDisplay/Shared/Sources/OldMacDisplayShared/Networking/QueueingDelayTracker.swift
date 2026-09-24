import Foundation

/// Measures how much later than "on schedule" frames are arriving, without
/// needing the two clocks to agree.
///
/// Every frame carries its capture time on the Host's clock. `arrival - pts`
/// is therefore (clock offset + network/encode delay). The offset is constant,
/// so the *minimum* of that difference over a window is the best case the link
/// can do, and anything above it is queueing: bytes sitting in a socket buffer
/// or a Wi-Fi retry. That excess is what the Host needs to hear about, because
/// its own send completions cannot see it (the kernel accepts bytes into the
/// socket buffer instantly whether or not the link is moving).
///
/// The baseline is a windowed minimum rather than a global one so that a
/// route change or a genuinely slower link does not read as permanent
/// congestion.
public struct QueueingDelayTracker: Equatable {
    /// Seconds of history the baseline minimum is taken over.
    public let baselineWindow: Double

    /// One minimum per second of arrivals, oldest first.
    private var buckets: [(second: Int, minimum: Double)] = []
    /// Worst excess seen since the last `report()`.
    private var windowMax: Double = 0
    private var windowSum: Double = 0
    private var windowCount = 0

    public init(baselineWindow: Double = 10) {
        self.baselineWindow = baselineWindow
    }

    public static func == (lhs: QueueingDelayTracker, rhs: QueueingDelayTracker) -> Bool {
        lhs.baselineWindow == rhs.baselineWindow
            && lhs.buckets.map { $0.second } == rhs.buckets.map { $0.second }
            && lhs.buckets.map { $0.minimum } == rhs.buckets.map { $0.minimum }
            && lhs.windowMax == rhs.windowMax
    }

    /// Records one frame. `presentationTime` is on the sender's clock,
    /// `arrival` on ours; both in seconds.
    public mutating func record(presentationTime: Double, arrival: Double) {
        let difference = arrival - presentationTime
        guard difference.isFinite else { return }

        let second = Int(arrival.rounded(.down))
        if let last = buckets.last, last.second == second {
            buckets[buckets.count - 1].minimum = Swift.min(last.minimum, difference)
        } else {
            buckets.append((second, difference))
        }
        let cutoff = second - Int(baselineWindow)
        buckets.removeAll { $0.second < cutoff }

        let excess = Swift.max(0, difference - baseline)
        windowMax = Swift.max(windowMax, excess)
        windowSum += excess
        windowCount += 1
    }

    /// The best-case (arrival - pts) currently in the window.
    private var baseline: Double {
        buckets.map { $0.minimum }.min() ?? 0
    }

    public struct Report: Equatable {
        public let maxMillis: Double
        public let averageMillis: Double
        public let frameCount: Int
    }

    /// Returns the excess seen since the last report and starts a new window.
    public mutating func report() -> Report? {
        guard windowCount > 0 else { return nil }
        let report = Report(maxMillis: windowMax * 1000,
                            averageMillis: windowSum / Double(windowCount) * 1000,
                            frameCount: windowCount)
        windowMax = 0
        windowSum = 0
        windowCount = 0
        return report
    }

    public mutating func reset() {
        buckets.removeAll()
        windowMax = 0
        windowSum = 0
        windowCount = 0
    }
}
