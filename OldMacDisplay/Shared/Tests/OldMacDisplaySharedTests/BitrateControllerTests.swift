import XCTest
@testable import OldMacDisplayShared

final class BitrateControllerTests: XCTestCase {

    private let target = 12_000_000

    func testStartsAtNegotiatedTarget() {
        let controller = BitrateController(targetBPS: target)
        XCTAssertEqual(controller.currentBPS, target)
        XCTAssertEqual(controller.ceilingBPS, target)
    }

    func testCleanReportsDoNothingAtCeiling() {
        var controller = BitrateController(targetBPS: target)
        for second in 0..<10 {
            XCTAssertNil(controller.update(.init(), now: Double(second)))
        }
        XCTAssertEqual(controller.currentBPS, target)
    }

    /// Soft signals need two consecutive bad reports: one late second is
    /// jitter and must not cost quality, and a clean report in between
    /// starts the count over.
    func testASingleBadSoftWindowIsIgnored() {
        var controller = BitrateController(targetBPS: target)
        XCTAssertNil(controller.update(.init(receiverDropRatio: 0.1), now: 0))
        XCTAssertNil(controller.update(.init(), now: 1))
        XCTAssertNil(controller.update(.init(queueingDelayMillis: 200), now: 2))
        XCTAssertNil(controller.update(.init(), now: 3))
        XCTAssertEqual(controller.currentBPS, target)
    }

    func testReceiverDropsCutBitrate() {
        var controller = BitrateController(targetBPS: target)
        XCTAssertNil(controller.update(.init(receiverDropRatio: 0.1), now: 0))
        let result = controller.update(.init(receiverDropRatio: 0.1), now: 1)
        XCTAssertEqual(result, 8_400_000)
        XCTAssertEqual(controller.currentBPS, 8_400_000)
    }

    func testQueueingDelayCutsBitrate() {
        var controller = BitrateController(targetBPS: target)
        XCTAssertNil(controller.update(.init(queueingDelayMillis: 200), now: 0))
        XCTAssertNotNil(controller.update(.init(queueingDelayMillis: 200), now: 1))
        XCTAssertLessThan(controller.currentBPS, target)
    }

    func testOneFrameOfQueueingIsNotCongestion() {
        var controller = BitrateController(targetBPS: target)
        for second in 0..<10 {
            XCTAssertNil(controller.update(.init(queueingDelayMillis: 40), now: Double(second)))
        }
        XCTAssertEqual(controller.currentBPS, target)
    }

    func testHostSideDropsCutBitrateAtOnce() {
        var controller = BitrateController(targetBPS: target)
        XCTAssertNotNil(controller.update(.init(hostDroppedFrames: 3), now: 0))
    }

    func testHighRTTCutsBitrate() {
        var controller = BitrateController(targetBPS: target)
        XCTAssertNil(controller.update(.init(rttMillis: 400), now: 0))
        XCTAssertNotNil(controller.update(.init(rttMillis: 400), now: 1))
    }

    func testDecreaseHasCooldown() {
        var controller = BitrateController(targetBPS: target)
        XCTAssertNotNil(controller.update(.init(hostDroppedFrames: 1), now: 0))
        // One bad second must not be punished again before its effect shows.
        XCTAssertNil(controller.update(.init(hostDroppedFrames: 1), now: 1))
        XCTAssertNotNil(controller.update(.init(hostDroppedFrames: 1), now: 2.5))
    }

    func testNeverGoesBelowFloor() {
        var controller = BitrateController(targetBPS: target, floorBPS: 2_000_000)
        var now = 0.0
        for _ in 0..<40 {
            _ = controller.update(.init(hostDroppedFrames: 1), now: now)
            now += 3
        }
        XCTAssertEqual(controller.currentBPS, 2_000_000)
        XCTAssertNil(controller.update(.init(hostDroppedFrames: 1), now: now + 3))
    }

    func testRecoversSlowlyAfterCleanWindows() {
        var controller = BitrateController(targetBPS: target)
        XCTAssertEqual(controller.update(.init(hostDroppedFrames: 2), now: 0), 8_400_000)

        // Hold period after a decrease: clean seconds inside it never raise
        // the bitrate, however many there are.
        XCTAssertNil(controller.update(.init(), now: 1))
        XCTAssertNil(controller.update(.init(), now: 2))
        XCTAssertNil(controller.update(.init(), now: 3))
        XCTAssertNil(controller.update(.init(), now: 4))

        // Once the hold has passed, the accumulated clean windows count.
        XCTAssertEqual(controller.update(.init(), now: 6), 9_700_000)
        // And the next step needs three more clean windows.
        XCTAssertNil(controller.update(.init(), now: 7))
        XCTAssertNil(controller.update(.init(), now: 8))
        XCTAssertEqual(controller.update(.init(), now: 9), 11_200_000)
    }

    func testRecoveryNeverExceedsCeiling() {
        var controller = BitrateController(targetBPS: target)
        _ = controller.update(.init(hostDroppedFrames: 2), now: 0)
        var now = 10.0
        for _ in 0..<60 {
            _ = controller.update(.init(), now: now)
            now += 1
        }
        XCTAssertEqual(controller.currentBPS, target)
    }

    func testCongestionResetsCleanStreak() {
        var controller = BitrateController(targetBPS: target)
        _ = controller.update(.init(hostDroppedFrames: 2), now: 0)
        XCTAssertNil(controller.update(.init(), now: 10))
        XCTAssertNil(controller.update(.init(), now: 11))
        // A bad window cuts again and resets the streak: had the two clean
        // windows above survived, the one at 17 would already have raised it.
        XCTAssertEqual(controller.update(.init(hostDroppedFrames: 2), now: 11.5), 5_900_000)
        XCTAssertNil(controller.update(.init(), now: 17))
        XCTAssertNil(controller.update(.init(), now: 18))
        XCTAssertNotNil(controller.update(.init(), now: 19))
    }

    func testTargetBelowFloorIsClampedSanely() {
        let controller = BitrateController(targetBPS: 1_000_000, floorBPS: 2_000_000)
        XCTAssertEqual(controller.floorBPS, controller.ceilingBPS)
        XCTAssertEqual(controller.currentBPS, 2_000_000)
    }
}
