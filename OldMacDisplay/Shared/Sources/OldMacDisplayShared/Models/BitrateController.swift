import Foundation

/// Adapts the encoder bitrate to what the link is actually delivering.
///
/// Driven once a second by the Receiver's `networkStats` report, which is the
/// only honest view of congestion in the system. Deliberately asymmetric:
/// backs off fast (a stall is visible immediately) and recovers slowly (a
/// premature increase just re-triggers the stall). Pure, so the policy is
/// unit-tested without a network.
public struct BitrateController: Equatable {
    public struct Input: Equatable {
        /// Fraction of frames the Receiver's renderer had to discard.
        public var receiverDropRatio: Double
        /// Worst queueing excess the Receiver measured in the window, ms.
        public var queueingDelayMillis: Double?
        /// Frames the Host dropped on the send side during the window.
        public var hostDroppedFrames: Int
        /// Smoothed RTT, ms, if known.
        public var rttMillis: Double?

        public init(receiverDropRatio: Double = 0,
                    queueingDelayMillis: Double? = nil,
                    hostDroppedFrames: Int = 0,
                    rttMillis: Double? = nil) {
            self.receiverDropRatio = receiverDropRatio
            self.queueingDelayMillis = queueingDelayMillis
            self.hostDroppedFrames = hostDroppedFrames
            self.rttMillis = rttMillis
        }
    }

    public struct Thresholds: Equatable {
        public var dropRatio: Double = 0.05
        /// Well above one frame interval: a single late frame is jitter, not
        /// congestion. Measured on a loopback the steady-state excess was
        /// already ~20 ms.
        public var queueingDelayMillis: Double = 100
        public var rttMillis: Double = 150
        /// Consecutive congested reports required before the soft signals
        /// (drop ratio, queueing, RTT) cut the bitrate. Host-side drops are
        /// unambiguous and act at once.
        public var congestedWindowsBeforeDecrease = 2
        /// Multiplier applied on congestion.
        public var decreaseFactor: Double = 0.7
        /// Multiplier applied on each recovery step.
        public var increaseFactor: Double = 1.15
        /// Clean windows required before recovering.
        public var cleanWindowsBeforeIncrease = 3
        /// Minimum seconds between two decreases, so one bad second is not
        /// punished three times before its effect is even visible.
        public var decreaseCooldown: Double = 2
        /// Minimum seconds after a decrease before any increase.
        public var holdAfterDecrease: Double = 5
        public init() {}
    }

    public let floorBPS: Int
    public let ceilingBPS: Int
    public var thresholds: Thresholds

    public private(set) var currentBPS: Int
    private var cleanWindows = 0
    private var congestedWindows = 0
    private var lastDecreaseAt: Double?
    private var lastIncreaseAt: Double?

    public init(targetBPS: Int, floorBPS: Int = 2_000_000, thresholds: Thresholds = Thresholds()) {
        self.ceilingBPS = Swift.max(targetBPS, floorBPS)
        self.floorBPS = Swift.min(floorBPS, ceilingBPS)
        self.currentBPS = ceilingBPS
        self.thresholds = thresholds
    }

    public static func isCongested(_ input: Input, thresholds: Thresholds) -> Bool {
        if input.hostDroppedFrames > 0 { return true }
        if input.receiverDropRatio > thresholds.dropRatio { return true }
        if let queueing = input.queueingDelayMillis, queueing > thresholds.queueingDelayMillis { return true }
        if let rtt = input.rttMillis, rtt > thresholds.rttMillis { return true }
        return false
    }

    /// Feeds one report. Returns the new bitrate when it should change.
    public mutating func update(_ input: Input, now: Double) -> Int? {
        if BitrateController.isCongested(input, thresholds: thresholds) {
            cleanWindows = 0
            congestedWindows += 1
            let decisive = input.hostDroppedFrames > 0
                || congestedWindows >= thresholds.congestedWindowsBeforeDecrease
            guard decisive else { return nil }
            if let last = lastDecreaseAt, now - last < thresholds.decreaseCooldown {
                return nil
            }
            lastDecreaseAt = now
            congestedWindows = 0
            return apply(Double(currentBPS) * thresholds.decreaseFactor)
        }

        congestedWindows = 0
        cleanWindows += 1
        guard cleanWindows >= thresholds.cleanWindowsBeforeIncrease,
              currentBPS < ceilingBPS else { return nil }
        if let last = lastDecreaseAt, now - last < thresholds.holdAfterDecrease {
            return nil
        }
        cleanWindows = 0
        lastIncreaseAt = now
        return apply(Double(currentBPS) * thresholds.increaseFactor)
    }

    private mutating func apply(_ proposed: Double) -> Int? {
        // Round to 100 kbps: the encoder's rate controller does not resolve
        // finer than that, and round numbers read better in the log.
        let rounded = Int((proposed / 100_000).rounded()) * 100_000
        let clamped = Swift.min(Swift.max(rounded, floorBPS), ceilingBPS)
        guard clamped != currentBPS else { return nil }
        currentBPS = clamped
        return clamped
    }
}
