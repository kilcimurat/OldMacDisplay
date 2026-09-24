import Foundation

/// Lifecycle of a Host<->Receiver link.
public enum ConnectionState: Equatable {
    case idle
    case connecting
    /// Transport is up; protocol handshake (Hello/Capabilities) not finished.
    case handshaking
    case connected
    /// Transport dropped but we are within the grace period and retrying.
    case reconnecting(attempt: Int)
    case disconnected(reason: String)
}

public enum ConnectionEvent: Equatable {
    case connectRequested
    case transportReady
    case handshakeCompleted
    case transportFailed(reason: String)
    case retryScheduled
    case gracePeriodExpired
    case disconnectRequested(reason: String)
}

/// Pure, side-effect-free state machine for the connection lifecycle.
///
/// Keeping this separate from `NWConnection` is what makes reconnect behaviour
/// unit-testable without a second Mac: tests drive events directly.
public struct ConnectionStateMachine: Equatable {
    public private(set) var state: ConnectionState
    /// How many reconnect attempts before giving up is a policy decision left to
    /// the caller; the machine only counts them.
    public private(set) var reconnectAttempts: Int

    public init(state: ConnectionState = .idle) {
        self.state = state
        self.reconnectAttempts = 0
    }

    /// Applies an event. Returns `true` if the state actually changed, so callers
    /// can avoid redundant UI updates.
    @discardableResult
    public mutating func handle(_ event: ConnectionEvent) -> Bool {
        let previous = state

        switch (state, event) {
        case (_, .disconnectRequested(let reason)):
            state = .disconnected(reason: reason)
            reconnectAttempts = 0

        case (.idle, .connectRequested),
             (.disconnected, .connectRequested):
            state = .connecting
            reconnectAttempts = 0

        case (.connecting, .transportReady),
             (.reconnecting, .transportReady):
            state = .handshaking

        case (.handshaking, .handshakeCompleted):
            state = .connected
            reconnectAttempts = 0

        // A drop from an established or in-progress link enters the grace period
        // rather than terminating: a yanked Ethernet cable must not destroy the
        // session (or, later, the virtual display).
        case (.connecting, .transportFailed),
             (.handshaking, .transportFailed),
             (.connected, .transportFailed),
             (.reconnecting, .transportFailed):
            reconnectAttempts += 1
            state = .reconnecting(attempt: reconnectAttempts)

        case (.reconnecting, .retryScheduled):
            break // already reconnecting; keep the current attempt count

        case (.reconnecting, .gracePeriodExpired):
            state = .disconnected(reason: "Reconnect timed out")
            reconnectAttempts = 0

        default:
            // Ignore events that make no sense in the current state rather than
            // trapping; the network layer can deliver stale callbacks.
            break
        }

        return state != previous
    }

    public var isActive: Bool {
        switch state {
        case .connecting, .handshaking, .connected, .reconnecting: return true
        case .idle, .disconnected: return false
        }
    }
}
