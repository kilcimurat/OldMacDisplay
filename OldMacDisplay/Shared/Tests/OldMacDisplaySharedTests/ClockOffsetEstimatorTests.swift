import XCTest
@testable import OldMacDisplayShared

final class ClockOffsetEstimatorTests: XCTestCase {

    func testNoEstimateBeforeAnySample() {
        let estimator = ClockOffsetEstimator()
        XCTAssertNil(estimator.offset)
        XCTAssertNil(estimator.localTime(forPeerTime: 100))
    }

    func testSymmetricRoundTripRecoversExactOffset() {
        var estimator = ClockOffsetEstimator()
        // Peer clock is 1000 s ahead; 10 ms each way.
        estimator.record(sentAt: 50.000, peerReceivedAt: 1050.010, returnedAt: 50.020)
        XCTAssertEqual(estimator.offset ?? .nan, 1000.0, accuracy: 1e-9)
        XCTAssertEqual(estimator.localTime(forPeerTime: 1060) ?? .nan, 60, accuracy: 1e-9)
    }

    func testPrefersTheSampleWithTheShortestRoundTrip() {
        var estimator = ClockOffsetEstimator()
        // A queued return leg makes the midpoint assumption wrong by 100 ms.
        estimator.record(sentAt: 0, peerReceivedAt: 1000.005, returnedAt: 0.210)
        XCTAssertEqual(estimator.offset ?? .nan, 1000.005 - 0.105, accuracy: 1e-9)
        // A clean sample supersedes it, whatever the order.
        estimator.record(sentAt: 1, peerReceivedAt: 1001.005, returnedAt: 1.010)
        XCTAssertEqual(estimator.offset ?? .nan, 1000.0, accuracy: 1e-9)
        estimator.record(sentAt: 2, peerReceivedAt: 1002.005, returnedAt: 2.500)
        XCTAssertEqual(estimator.offset ?? .nan, 1000.0, accuracy: 1e-9)
    }

    func testOldSamplesLeaveTheWindow() {
        var estimator = ClockOffsetEstimator(window: 5)
        estimator.record(sentAt: 0, peerReceivedAt: 1000.001, returnedAt: 0.002)
        XCTAssertEqual(estimator.sampleCount, 1)
        // A worse sample later; the good one is still in the window.
        estimator.record(sentAt: 3, peerReceivedAt: 1003.050, returnedAt: 3.100)
        XCTAssertEqual(estimator.offset ?? .nan, 1000.0, accuracy: 1e-9)
        // Beyond the window only the newer sample remains.
        estimator.record(sentAt: 10, peerReceivedAt: 1010.050, returnedAt: 10.100)
        XCTAssertEqual(estimator.sampleCount, 1)
        XCTAssertEqual(estimator.offset ?? .nan, 1010.050 - 10.050, accuracy: 1e-9)
    }

    func testRejectsNegativeRoundTrips() {
        var estimator = ClockOffsetEstimator()
        estimator.record(sentAt: 10, peerReceivedAt: 1000, returnedAt: 9)
        XCTAssertNil(estimator.offset)
    }

    func testResetClearsEverything() {
        var estimator = ClockOffsetEstimator()
        estimator.record(sentAt: 0, peerReceivedAt: 1000, returnedAt: 0.01)
        estimator.reset()
        XCTAssertNil(estimator.offset)
        XCTAssertEqual(estimator.sampleCount, 0)
    }
}
