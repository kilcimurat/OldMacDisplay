import XCTest
@testable import OldMacDisplayShared

final class HeartbeatTests: XCTestCase {

    /// Controllable clock so RTT maths is verified exactly, with no sleeping.
    private final class FakeClock {
        var time: Double = 1000.0
        func now() -> Double { time }
    }

    func testPingIsAnsweredWithAnEchoingPong() {
        var sent: [ControlMessage] = []
        let hb = Heartbeat(queue: .main, send: { sent.append($0) })

        let ping = ControlMessage.Ping(sequence: 9, sentAt: 555.25)
        XCTAssertTrue(hb.handle(.ping(ping)))
        XCTAssertEqual(sent.count, 1)
        guard case .pong(let pong)? = sent.first else {
            return XCTFail("expected a pong, got \(String(describing: sent.first))")
        }
        XCTAssertEqual(pong.sequence, 9)
        XCTAssertEqual(pong.sentAt, 555.25)
    }

    func testRoundTripTimeIsComputedFromTheEchoedTimestamp() {
        let clock = FakeClock()
        var sent: [ControlMessage] = []
        let hb = Heartbeat(queue: .main, now: clock.now, send: { sent.append($0) })

        hb.sendPing()
        guard case .ping(let ping)? = sent.first else { return XCTFail("no ping sent") }

        clock.time += 0.012 // 12 ms later the pong comes back
        hb.handle(.pong(ControlMessage.Pong(echoing: ping)))

        XCTAssertEqual(hb.tracker.lastRTT ?? 0, 0.012, accuracy: 1e-9)
        XCTAssertEqual(hb.tracker.smoothedMilliseconds ?? 0, 12.0, accuracy: 1e-6)
    }

    /// The pong carries the responder's clock, and the pinger turns that into
    /// a clock offset it can convert peer timestamps with.
    func testPongCarriesReceiverClockAndPingerEstimatesOffset() {
        let hostClock = FakeClock()
        hostClock.time = 5000
        let receiverClock = FakeClock()
        receiverClock.time = 100

        var hostToReceiver: [ControlMessage] = []
        var receiverToHost: [ControlMessage] = []
        let host = Heartbeat(queue: .main, now: hostClock.now, send: { hostToReceiver.append($0) })
        let receiver = Heartbeat(queue: .main, now: receiverClock.now, send: { receiverToHost.append($0) })

        receiver.sendPing()
        guard case .ping(let ping)? = receiverToHost.first else { return XCTFail("no ping") }

        // 4 ms on the wire each way.
        hostClock.time += 0.004
        receiverClock.time += 0.004
        XCTAssertTrue(host.handle(ping.asMessage))
        guard case .pong(let pong)? = hostToReceiver.first else { return XCTFail("no pong") }
        XCTAssertEqual(pong.receivedAt, 5000.004)

        hostClock.time += 0.004
        receiverClock.time += 0.004
        XCTAssertTrue(receiver.handle(.pong(pong)))

        XCTAssertEqual(receiver.clockOffset.offset ?? .nan, 4900, accuracy: 1e-9)
        // A frame captured at host time 5000.5 happened at receiver time 100.5.
        XCTAssertEqual(receiver.clockOffset.localTime(forPeerTime: 5000.5) ?? .nan, 100.5, accuracy: 1e-9)
    }

    /// A peer that has gone silent is reported once, after `timeout`, and
    /// any inbound message resets the clock.
    func testSilentPeerTimesOutOnce() {
        let clock = FakeClock()
        var timeouts = 0
        var pings = 0
        let hb = Heartbeat(interval: 1, timeout: 6, queue: .main, now: clock.now, send: { message in
            if case .ping = message { pings += 1 }
        })
        hb.onTimeout = { timeouts += 1 }
        hb.start()
        defer { hb.stop() }

        // Alive: a message arrives, then five quiet seconds are fine.
        hb.handle(.streamStart)
        for _ in 0..<5 {
            clock.time += 1
            hb.tick()
        }
        XCTAssertEqual(timeouts, 0)

        // Anything inbound resets the deadline.
        hb.handle(.pong(.init(sequence: 1, sentAt: clock.time - 0.01)))
        clock.time += 5.9
        hb.tick()
        XCTAssertEqual(timeouts, 0)

        clock.time += 0.2
        hb.tick()
        XCTAssertEqual(timeouts, 1)
        let pingsAtTimeout = pings
        // Reported once; no further pings into the void.
        clock.time += 1
        hb.tick()
        XCTAssertEqual(timeouts, 1)
        XCTAssertEqual(pings, pingsAtTimeout)
    }

    func testSequenceNumbersIncrement() {
        var sequences: [UInt32] = []
        let hb = Heartbeat(queue: .main, send: { message in
            if case .ping(let p) = message { sequences.append(p.sequence) }
        })
        (0..<3).forEach { _ in hb.sendPing() }
        XCTAssertEqual(sequences, [1, 2, 3])
    }

    func testNonHeartbeatMessagesAreNotConsumed() {
        let hb = Heartbeat(queue: .main, send: { _ in })
        XCTAssertFalse(hb.handle(.streamStart))
        XCTAssertFalse(hb.handle(.disconnect(.init(reason: "bye"))))
    }

    /// A pong whose timestamp is in the future (clock glitch, replayed packet)
    /// must be discarded rather than recorded as a negative latency.
    func testPongFromTheFutureIsDiscarded() {
        let clock = FakeClock()
        let hb = Heartbeat(queue: .main, now: clock.now, send: { _ in })
        hb.handle(.pong(ControlMessage.Pong(sequence: 1, sentAt: clock.time + 5)))
        XCTAssertEqual(hb.tracker.sampleCount, 0)
    }

    func testOnSampleFiresForEachPong() {
        let clock = FakeClock()
        var callbacks = 0
        let hb = Heartbeat(queue: .main, now: clock.now, send: { _ in })
        hb.onSample = { _ in callbacks += 1 }

        for i in 1...3 {
            clock.time += 0.01
            hb.handle(.pong(ControlMessage.Pong(sequence: UInt32(i), sentAt: clock.time - 0.01)))
        }
        XCTAssertEqual(callbacks, 3)
        XCTAssertEqual(hb.tracker.sampleCount, 3)
    }

    /// Exercises heartbeat + framing + transport together, which is as close to
    /// the real Host<->Receiver exchange as a unit test can get.
    func testHeartbeatOverLoopbackTransport() {
        let clock = FakeClock()
        let (hostSide, receiverSide) = LoopbackTransport.pair()

        let hostHeartbeat = Heartbeat(queue: .main, now: clock.now) { message in
            try? hostSide.sendControl(message)
        }
        let receiverHeartbeat = Heartbeat(queue: .main, now: clock.now) { message in
            try? receiverSide.sendControl(message)
        }

        hostSide.onFrame = { frame in
            guard frame.channel == .control,
                  let message = try? ControlCodec.decode(frame.payload) else { return }
            hostHeartbeat.handle(message)
        }
        receiverSide.onFrame = { frame in
            guard frame.channel == .control,
                  let message = try? ControlCodec.decode(frame.payload) else { return }
            // Simulate 8 ms of one-way delay before the reply is generated.
            clock.time += 0.008
            receiverHeartbeat.handle(message)
        }

        hostHeartbeat.sendPing()
        XCTAssertEqual(hostHeartbeat.tracker.lastRTT ?? 0, 0.008, accuracy: 1e-9)
    }
}


private extension ControlMessage.Ping {
    var asMessage: ControlMessage { .ping(self) }
}
