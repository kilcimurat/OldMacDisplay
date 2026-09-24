import XCTest
@testable import OldMacDisplayShared

final class QueueingDelayTrackerTests: XCTestCase {

    /// Frames every 1/60 s whose arrival trails their pts by a constant offset.
    private func feedSteady(_ tracker: inout QueueingDelayTracker, seconds: Double,
                            offset: Double, from start: Double = 0) {
        for index in 0..<Int((seconds * 60).rounded()) {
            let t = start + Double(index) / 60
            tracker.record(presentationTime: t, arrival: t + offset)
        }
    }

    func testNoReportWithoutFrames() {
        var tracker = QueueingDelayTracker()
        XCTAssertNil(tracker.report())
    }

    func testSteadyStreamShowsNoQueueingWhateverTheClockOffset() {
        var tracker = QueueingDelayTracker()
        feedSteady(&tracker, seconds: 2, offset: 12345.678)
        let report = tracker.report()
        XCTAssertEqual(report?.maxMillis ?? .nan, 0, accuracy: 1e-6)
        XCTAssertEqual(report?.frameCount, 120)
    }

    func testLateFramesShowAsExcessOverBaseline() {
        var tracker = QueueingDelayTracker()
        feedSteady(&tracker, seconds: 1, offset: 0.020)
        _ = tracker.report()
        // A stall: frames from the next second all arrive 150 ms extra late.
        feedSteady(&tracker, seconds: 1, offset: 0.170, from: 1)
        let report = tracker.report()
        XCTAssertEqual(report?.maxMillis ?? .nan, 150, accuracy: 0.01)
        XCTAssertEqual(report?.averageMillis ?? .nan, 150, accuracy: 0.01)
    }

    func testReportResetsTheWindowButNotTheBaseline() {
        var tracker = QueueingDelayTracker()
        feedSteady(&tracker, seconds: 1, offset: 0.020)
        feedSteady(&tracker, seconds: 1, offset: 0.120, from: 1)
        _ = tracker.report()
        feedSteady(&tracker, seconds: 1, offset: 0.020, from: 2)
        XCTAssertEqual(tracker.report()?.maxMillis ?? .nan, 0, accuracy: 1e-6)
    }

    func testBaselineForgetsAFasterPastAfterTheWindow() {
        var tracker = QueueingDelayTracker(baselineWindow: 3)
        feedSteady(&tracker, seconds: 1, offset: 0.010)
        _ = tracker.report()
        // The route got permanently slower by 80 ms.
        feedSteady(&tracker, seconds: 1, offset: 0.090, from: 1)
        XCTAssertEqual(tracker.report()?.maxMillis ?? .nan, 80, accuracy: 0.01)
        // Once the fast second has aged out, the new steady state is normal.
        feedSteady(&tracker, seconds: 5, offset: 0.090, from: 2)
        _ = tracker.report()
        feedSteady(&tracker, seconds: 1, offset: 0.090, from: 7)
        XCTAssertEqual(tracker.report()?.maxMillis ?? .nan, 0, accuracy: 1e-6)
    }

    func testResetClearsBaseline() {
        var tracker = QueueingDelayTracker()
        feedSteady(&tracker, seconds: 1, offset: 0.010)
        tracker.reset()
        feedSteady(&tracker, seconds: 1, offset: 0.500)
        XCTAssertEqual(tracker.report()?.maxMillis ?? .nan, 0, accuracy: 1e-6)
    }
}
