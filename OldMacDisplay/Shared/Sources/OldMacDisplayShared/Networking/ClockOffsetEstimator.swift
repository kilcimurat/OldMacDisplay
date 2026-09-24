import Foundation

/// Estimates the offset between the peer's monotonic clock and ours from the
/// Ping/Pong exchange, so a timestamp stamped on the Host (a frame's capture
/// time) can be compared with a local time on the Receiver.
///
/// Classic NTP-style: for each pong, the peer's clock read at `receivedAt` is
/// assumed to correspond to the midpoint of the round trip. The sample taken
/// on the shortest RTT is the most trustworthy, because asymmetric queueing is
/// what corrupts the midpoint assumption, and queueing only ever adds delay.
/// The estimate is therefore the offset of the minimum-RTT sample within a
/// sliding window, not an average.
public struct ClockOffsetEstimator: Equatable {
    public struct Sample: Equatable {
        public let offset: Double
        public let rtt: Double
        public let takenAt: Double
    }

    /// How long a sample stays eligible. Long enough to ride out a few noisy
    /// seconds, short enough that clock drift (typically well under 100 ppm,
    /// i.e. < 1 ms per 10 s) stays negligible.
    public let window: Double
    private var samples: [Sample] = []

    public init(window: Double = 20) {
        self.window = window
    }

    /// `sentAt` and `returnedAt` are on our clock; `peerReceivedAt` on theirs.
    public mutating func record(sentAt: Double, peerReceivedAt: Double, returnedAt: Double) {
        let rtt = returnedAt - sentAt
        guard rtt >= 0, rtt.isFinite, peerReceivedAt.isFinite else { return }
        let offset = peerReceivedAt - (sentAt + rtt / 2)
        samples.append(Sample(offset: offset, rtt: rtt, takenAt: returnedAt))
        samples.removeAll { returnedAt - $0.takenAt > window }
    }

    /// Peer clock minus our clock, in seconds. `nil` until the first sample.
    public var offset: Double? {
        samples.min { $0.rtt < $1.rtt }?.offset
    }

    public var sampleCount: Int { samples.count }

    /// Converts a timestamp on the peer's clock to our clock.
    public func localTime(forPeerTime peerTime: Double) -> Double? {
        offset.map { peerTime - $0 }
    }

    public mutating func reset() {
        samples.removeAll()
    }
}
