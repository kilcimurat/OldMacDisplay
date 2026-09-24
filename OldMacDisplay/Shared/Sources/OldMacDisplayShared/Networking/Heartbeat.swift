import Foundation

/// Drives the Ping/Pong exchange and maintains RTT statistics.
///
/// Symmetric: both Host and Receiver run one, so each side can display its own
/// measured latency without trusting a number reported by the peer. The clock is
/// injectable so the timing logic is unit-testable without real delays.
public final class Heartbeat {
    /// Called on `queue` whenever a new RTT sample lands.
    public var onSample: ((LatencyTracker) -> Void)?

    public private(set) var tracker = LatencyTracker()
    /// Peer clock relative to ours, refined with every pong that carries a
    /// `receivedAt`. Lets the Receiver turn Host capture timestamps into local
    /// time for a true capture-to-display latency figure.
    public private(set) var clockOffset = ClockOffsetEstimator()

    private let interval: Double
    private let queue: DispatchQueue
    private let now: () -> Double
    private let send: (ControlMessage) -> Void
    private var timer: DispatchSourceTimer?
    private var sequence: UInt32 = 0
    private let log = Log(.network)

    public init(interval: Double = 1.0,
                queue: DispatchQueue,
                now: @escaping () -> Double = MonotonicClock.now,
                send: @escaping (ControlMessage) -> Void) {
        self.interval = interval
        self.queue = queue
        self.now = now
        self.send = send
    }

    deinit { timer?.cancel() }

    public func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.sendPing() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func reset() {
        tracker.reset()
        clockOffset.reset()
        sequence = 0
    }

    /// Emits one ping immediately. Exposed for tests and for a manual "measure
    /// now" action in the diagnostics overlay.
    public func sendPing() {
        sequence &+= 1
        send(.ping(ControlMessage.Ping(sequence: sequence, sentAt: now())))
    }

    /// Feed every inbound control message here; returns true if it was consumed.
    @discardableResult
    public func handle(_ message: ControlMessage) -> Bool {
        switch message {
        case .ping(let ping):
            // Reply immediately and on this queue: any delay here is
            // indistinguishable from network latency to the peer.
            send(.pong(ControlMessage.Pong(echoing: ping, receivedAt: now())))
            return true

        case .pong(let pong):
            let returnedAt = now()
            let rtt = returnedAt - pong.sentAt
            guard rtt >= 0 else {
                log.error("Discarding pong \(pong.sequence) with a negative RTT")
                return true
            }
            tracker.record(rtt: rtt)
            if let peerReceivedAt = pong.receivedAt {
                clockOffset.record(sentAt: pong.sentAt, peerReceivedAt: peerReceivedAt,
                                   returnedAt: returnedAt)
            }
            log.debug(String(format: "RTT seq %u: %.2f ms (smoothed %.2f ms)",
                             pong.sequence, rtt * 1000, tracker.smoothedMilliseconds ?? 0))
            onSample?(tracker)
            return true

        default:
            return false
        }
    }
}
