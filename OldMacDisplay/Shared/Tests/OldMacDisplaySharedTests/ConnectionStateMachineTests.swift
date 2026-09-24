import XCTest
@testable import OldMacDisplayShared

final class ConnectionStateMachineTests: XCTestCase {

    func testHappyPath() {
        var sm = ConnectionStateMachine()
        XCTAssertEqual(sm.state, .idle)
        XCTAssertTrue(sm.handle(.connectRequested))
        XCTAssertEqual(sm.state, .connecting)
        XCTAssertTrue(sm.handle(.transportReady))
        XCTAssertEqual(sm.state, .handshaking)
        XCTAssertTrue(sm.handle(.handshakeCompleted))
        XCTAssertEqual(sm.state, .connected)
        XCTAssertTrue(sm.isActive)
    }

    /// A briefly unplugged Ethernet cable must go Connected -> Reconnecting ->
    /// Connected without passing through Disconnected, because Disconnected is
    /// what will later tear the virtual display down.
    func testTransientDropRecoversWithoutDisconnecting() {
        var sm = ConnectionStateMachine()
        sm.handle(.connectRequested)
        sm.handle(.transportReady)
        sm.handle(.handshakeCompleted)

        sm.handle(.transportFailed(reason: "cable unplugged"))
        XCTAssertEqual(sm.state, .reconnecting(attempt: 1))
        XCTAssertTrue(sm.isActive, "reconnecting is still an active session")

        sm.handle(.transportReady)
        sm.handle(.handshakeCompleted)
        XCTAssertEqual(sm.state, .connected)
        XCTAssertEqual(sm.reconnectAttempts, 0, "a successful handshake resets the counter")
    }

    func testRepeatedFailuresIncrementAttemptCount() {
        var sm = ConnectionStateMachine()
        sm.handle(.connectRequested)
        sm.handle(.transportReady)
        sm.handle(.handshakeCompleted)

        for expected in 1...4 {
            sm.handle(.transportFailed(reason: "drop"))
            XCTAssertEqual(sm.state, .reconnecting(attempt: expected))
        }
        XCTAssertEqual(sm.reconnectAttempts, 4)
    }

    func testGracePeriodExpiryDisconnects() {
        var sm = ConnectionStateMachine()
        sm.handle(.connectRequested)
        sm.handle(.transportReady)
        sm.handle(.handshakeCompleted)
        sm.handle(.transportFailed(reason: "drop"))
        sm.handle(.gracePeriodExpired)

        XCTAssertEqual(sm.state, .disconnected(reason: "Reconnect timed out"))
        XCTAssertFalse(sm.isActive)
        XCTAssertEqual(sm.reconnectAttempts, 0)
    }

    func testExplicitDisconnectWinsFromAnyState() {
        let states: [ConnectionState] = [
            .idle, .connecting, .handshaking, .connected, .reconnecting(attempt: 3)
        ]
        for start in states {
            var sm = ConnectionStateMachine(state: start)
            sm.handle(.disconnectRequested(reason: "User quit"))
            XCTAssertEqual(sm.state, .disconnected(reason: "User quit"),
                           "failed from \(start)")
        }
    }

    func testReconnectAfterDisconnectStartsFresh() {
        var sm = ConnectionStateMachine(state: .disconnected(reason: "x"))
        XCTAssertTrue(sm.handle(.connectRequested))
        XCTAssertEqual(sm.state, .connecting)
        XCTAssertEqual(sm.reconnectAttempts, 0)
    }

    /// The network stack can deliver stale callbacks; nonsensical events must be
    /// ignored rather than corrupting state or trapping.
    func testOutOfOrderEventsAreIgnored() {
        var sm = ConnectionStateMachine()
        XCTAssertFalse(sm.handle(.handshakeCompleted))
        XCTAssertEqual(sm.state, .idle)
        XCTAssertFalse(sm.handle(.gracePeriodExpired))
        XCTAssertEqual(sm.state, .idle)
    }

    func testHandleReturnsFalseWhenStateUnchanged() {
        var sm = ConnectionStateMachine()
        sm.handle(.connectRequested)
        XCTAssertFalse(sm.handle(.connectRequested), "already connecting")
    }
}
