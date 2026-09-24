import XCTest
@testable import OldMacDisplayShared

final class LatencyTrackerTests: XCTestCase {

    func testFirstSampleSeedsTheAverage() {
        var t = LatencyTracker()
        t.record(rtt: 0.010)
        XCTAssertEqual(t.smoothedRTT, 0.010)
        XCTAssertEqual(t.smoothedMilliseconds, 10.0)
        XCTAssertEqual(t.sampleCount, 1)
    }

    func testSmoothingConvergesTowardSteadyState() {
        var t = LatencyTracker(smoothing: 0.5)
        t.record(rtt: 0.100)
        for _ in 0..<20 { t.record(rtt: 0.010) }
        let smoothed = try! XCTUnwrap(t.smoothedRTT)
        XCTAssertEqual(smoothed, 0.010, accuracy: 0.0005)
    }

    func testTracksMinMaxAndLast() {
        var t = LatencyTracker()
        [0.020, 0.005, 0.050, 0.012].forEach { t.record(rtt: $0) }
        XCTAssertEqual(t.minRTT, 0.005)
        XCTAssertEqual(t.maxRTT, 0.050)
        XCTAssertEqual(t.lastRTT, 0.012)
        XCTAssertEqual(t.sampleCount, 4)
    }

    /// A pong that arrives with a bogus timestamp would otherwise poison the
    /// average permanently.
    func testInvalidSamplesAreRejected() {
        var t = LatencyTracker()
        t.record(rtt: 0.010)
        t.record(rtt: -1)
        t.record(rtt: .nan)
        t.record(rtt: .infinity)
        XCTAssertEqual(t.smoothedRTT, 0.010)
        XCTAssertEqual(t.sampleCount, 1)
    }

    func testResetClearsEverything() {
        var t = LatencyTracker()
        t.record(rtt: 0.01)
        t.reset()
        XCTAssertNil(t.smoothedRTT)
        XCTAssertNil(t.minRTT)
        XCTAssertEqual(t.sampleCount, 0)
    }
}
