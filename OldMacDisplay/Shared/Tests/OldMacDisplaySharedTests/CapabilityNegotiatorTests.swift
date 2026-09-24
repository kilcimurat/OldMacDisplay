import XCTest
@testable import OldMacDisplayShared

final class CapabilityNegotiatorTests: XCTestCase {

    /// Approximates the real 27" 2013 iMac: 2560x1440, hardware H.264 decode,
    /// no HEVC decode block.
    private func iMac2013(width: Int = 2560,
                          height: Int = 1440,
                          hevc: Bool = false,
                          network: NetworkType = .ethernet,
                          fps: Int = 60) -> ClientCapabilities {
        ClientCapabilities(displayWidth: width, displayHeight: height,
                           backingScaleFactor: 1.0, preferredFPS: fps,
                           h264HardwareDecode: true, hevcHardwareDecode: hevc,
                           ethernetAvailable: network == .ethernet, wifiAvailable: true,
                           activeNetworkType: network,
                           cpuModel: "Intel Core i5", gpuModel: "Iris Pro", memoryGB: 16)
    }

    private func m2Max(hevcEncode: Bool = true) -> ServerCapabilities {
        ServerCapabilities(supportedCodecs: hevcEncode ? [.h264, .hevc] : [.h264],
                           h264HardwareEncode: true, hevcHardwareEncode: hevcEncode,
                           supportsVirtualDisplay: true, availableModes: [])
    }

    // MARK: - Codec

    func testAutoPicksH264WhenReceiverCannotDecodeHEVC() {
        let codec = CapabilityNegotiator.chooseCodec(
            client: iMac2013(hevc: false), server: m2Max(), preference: .auto)
        XCTAssertEqual(codec, .h264, "2013 iMac has no HEVC decode block")
    }

    func testAutoPicksHEVCOnlyWhenBothEndsHaveHardware() {
        XCTAssertEqual(
            CapabilityNegotiator.chooseCodec(client: iMac2013(hevc: true),
                                             server: m2Max(), preference: .auto),
            .hevc)
        XCTAssertEqual(
            CapabilityNegotiator.chooseCodec(client: iMac2013(hevc: true),
                                             server: m2Max(hevcEncode: false),
                                             preference: .auto),
            .h264, "host cannot encode HEVC in hardware")
    }

    /// Forcing HEVC must degrade to H.264 rather than produce a black screen.
    func testForcedHEVCFallsBackWhenUnsupported() {
        XCTAssertEqual(
            CapabilityNegotiator.chooseCodec(client: iMac2013(hevc: false),
                                             server: m2Max(), preference: .forced(.hevc)),
            .h264)
    }

    func testForcedH264IsAlwaysHonoured() {
        XCTAssertEqual(
            CapabilityNegotiator.chooseCodec(client: iMac2013(hevc: true),
                                             server: m2Max(), preference: .forced(.h264)),
            .h264)
    }

    // MARK: - Resolution

    func testAutoPrefersLargestLadderModeFittingThePanelOnEthernet() {
        let mode = CapabilityNegotiator.chooseMode(
            client: iMac2013(width: 2560, height: 1440, network: .ethernet),
            server: m2Max(), preference: .auto, frameRate: .auto)
        XCTAssertEqual(mode.width, 2560)
        XCTAssertEqual(mode.height, 1440)
    }

    /// Regression: a 2013 iMac on Wi-Fi was negotiated its full 2560x1440 at
    /// 60 fps and the result lagged badly — ~1.8x the pixels of 1080p over a
    /// link whose latency spiked to 640 ms. Auto must not do that.
    func testAutoCapsAtFullHDOnWiFi() {
        let mode = CapabilityNegotiator.chooseMode(
            client: iMac2013(width: 2560, height: 1440, network: .wifi),
            server: m2Max(), preference: .auto, frameRate: .auto)
        XCTAssertEqual(mode.width, 1920)
        XCTAssertEqual(mode.height, 1080)
    }

    func testWiFiCapAppliesToUnknownAndOtherLinksToo() {
        for network in [NetworkType.other, .unknown] {
            let mode = CapabilityNegotiator.chooseMode(
                client: iMac2013(width: 2560, height: 1440, network: network),
                server: m2Max(), preference: .auto, frameRate: .auto)
            XCTAssertEqual(mode.width * mode.height, 1920 * 1080,
                           "failed for \(network)")
        }
    }

    /// The cap is a ceiling, not a target: a small panel still gets its own size.
    func testWiFiCapDoesNotUpscaleASmallPanel() {
        let mode = CapabilityNegotiator.chooseMode(
            client: iMac2013(width: 1440, height: 900, network: .wifi),
            server: m2Max(), preference: .auto, frameRate: .auto)
        XCTAssertEqual(mode.width, 1440)
        XCTAssertEqual(mode.height, 900)
    }

    /// An explicit choice is the user's to make, cap or no cap.
    func testExplicitResolutionIgnoresTheWiFiCap() {
        let mode = CapabilityNegotiator.chooseMode(
            client: iMac2013(width: 2560, height: 1440, network: .wifi),
            server: m2Max(),
            preference: .fixed(width: 2560, height: 1440), frameRate: .auto)
        XCTAssertEqual(mode.width, 2560)
    }

    func testAutoOnA21InchIMacPicks1080p() {
        let mode = CapabilityNegotiator.chooseMode(
            client: iMac2013(width: 1920, height: 1080), server: m2Max(),
            preference: .auto, frameRate: .auto)
        XCTAssertEqual(mode.width, 1920)
        XCTAssertEqual(mode.height, 1080)
    }

    /// Nothing on the ladder fits a small panel; fall back to its native size
    /// rather than streaming an image it has to downscale.
    func testAutoFallsBackToNativeWhenNoLadderModeFits() {
        let mode = CapabilityNegotiator.chooseMode(
            client: iMac2013(width: 1024, height: 768), server: m2Max(),
            preference: .auto, frameRate: .auto)
        XCTAssertEqual(mode.width, 1024)
        XCTAssertEqual(mode.height, 768)
    }

    func testNativePreferenceUsesReceiverPanel() {
        let mode = CapabilityNegotiator.chooseMode(
            client: iMac2013(width: 2560, height: 1440), server: m2Max(),
            preference: .native, frameRate: .fixed(30))
        XCTAssertEqual(mode, DisplayMode(width: 2560, height: 1440, refreshRate: 30))
    }

    func testFixedPreferenceIsHonoured() {
        let mode = CapabilityNegotiator.chooseMode(
            client: iMac2013(), server: m2Max(),
            preference: .fixed(width: 1920, height: 1080), frameRate: .fixed(60))
        XCTAssertEqual(mode, DisplayMode(width: 1920, height: 1080, refreshRate: 60))
    }

    // MARK: - Frame rate

    func testAutoFrameRateNeverExceedsReceiverPreference() {
        XCTAssertEqual(
            CapabilityNegotiator.chooseFrameRate(client: iMac2013(fps: 30), preference: .auto),
            30)
    }

    func testFrameRateIsClampedToSaneBounds() {
        XCTAssertEqual(
            CapabilityNegotiator.chooseFrameRate(client: iMac2013(), preference: .fixed(240)), 60)
        XCTAssertEqual(
            CapabilityNegotiator.chooseFrameRate(client: iMac2013(), preference: .fixed(1)), 24)
    }

    // MARK: - Bitrate

    func testEthernetGetsMoreBitrateThanWiFi() {
        let mode = DisplayMode(width: 1920, height: 1080, refreshRate: 60)
        let wired = CapabilityNegotiator.chooseBitrate(
            mode: mode, codec: .h264, quality: .balanced, network: .ethernet)
        let wireless = CapabilityNegotiator.chooseBitrate(
            mode: mode, codec: .h264, quality: .balanced, network: .wifi)
        XCTAssertGreaterThan(wired, wireless)
        XCTAssertLessThanOrEqual(wireless, 20_000_000)
    }

    /// Sharp desktop text needs a real budget: Balanced 1080p60 on a wire must
    /// not open below what screen-sharing tools consider the floor.
    func testBalancedFullHDOnEthernetOpensAtACrispBitrate() {
        let mode = DisplayMode(width: 1920, height: 1080, refreshRate: 60)
        let wired = CapabilityNegotiator.chooseBitrate(
            mode: mode, codec: .h264, quality: .balanced, network: .ethernet)
        XCTAssertGreaterThanOrEqual(wired, 15_000_000)
    }

    func testQualityPresetsAreOrdered() {
        let mode = DisplayMode(width: 1920, height: 1080, refreshRate: 60)
        let rates = QualityPreset.allCases.map {
            CapabilityNegotiator.chooseBitrate(mode: mode, codec: .h264,
                                               quality: $0, network: .ethernet)
        }
        XCTAssertEqual(rates, rates.sorted(), "performance < balanced < quality")
    }

    func testHEVCUsesLessBitrateThanH264ForTheSameMode() {
        let mode = DisplayMode(width: 1920, height: 1080, refreshRate: 60)
        XCTAssertLessThan(
            CapabilityNegotiator.chooseBitrate(mode: mode, codec: .hevc,
                                               quality: .balanced, network: .ethernet),
            CapabilityNegotiator.chooseBitrate(mode: mode, codec: .h264,
                                               quality: .balanced, network: .ethernet))
    }

    func testBitrateAlwaysWithinFloorAndCeiling() {
        let tiny = DisplayMode(width: 640, height: 480, refreshRate: 24)
        XCTAssertGreaterThanOrEqual(
            CapabilityNegotiator.chooseBitrate(mode: tiny, codec: .hevc,
                                               quality: .performance, network: .wifi),
            2_000_000)

        let huge = DisplayMode(width: 5120, height: 2880, refreshRate: 60)
        XCTAssertLessThanOrEqual(
            CapabilityNegotiator.chooseBitrate(mode: huge, codec: .h264,
                                               quality: .quality, network: .ethernet),
            40_000_000)
    }

    // MARK: - End to end

    func testDefaultNegotiationForOurActualHardware() {
        let config = CapabilityNegotiator.negotiate(
            client: iMac2013(width: 2560, height: 1440, hevc: false, network: .ethernet),
            server: m2Max(),
            preferences: .default)

        XCTAssertEqual(config.codec, .h264)
        XCTAssertEqual(config.mode.refreshRate, 60)
        XCTAssertGreaterThan(config.targetBitrateBPS, 2_000_000)
    }
}
