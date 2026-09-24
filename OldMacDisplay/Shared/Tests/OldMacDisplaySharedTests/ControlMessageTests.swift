import XCTest
@testable import OldMacDisplayShared

final class ControlMessageTests: XCTestCase {

    private func sampleClientCapabilities() -> ClientCapabilities {
        ClientCapabilities(displayWidth: 2560, displayHeight: 1440,
                           backingScaleFactor: 1.0, preferredFPS: 60,
                           h264HardwareDecode: true, hevcHardwareDecode: false,
                           ethernetAvailable: true, wifiAvailable: true,
                           activeNetworkType: .ethernet,
                           cpuModel: "Intel Core i5-4570R", gpuModel: "Iris Pro 5200",
                           memoryGB: 16)
    }

    private func assertRoundTrip(_ message: ControlMessage,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try ControlCodec.encode(message)
        XCTAssertEqual(try ControlCodec.decode(data), message, file: file, line: line)
    }

    func testEveryMessageCaseRoundTrips() throws {
        let device = DeviceInfo(deviceID: "ABC-123", name: "Murat's MacBook Pro",
                                model: "Mac14,6", osVersion: "26.5.1")
        let config = SessionConfiguration(
            mode: DisplayMode(width: 1920, height: 1080, refreshRate: 60),
            codec: .h264, targetBitrateBPS: 11_000_000)

        try assertRoundTrip(.hello(.init(device: device)))
        try assertRoundTrip(.clientCapabilities(sampleClientCapabilities()))
        try assertRoundTrip(.serverCapabilities(.init(
            supportedCodecs: [.h264, .hevc], h264HardwareEncode: true,
            hevcHardwareEncode: true, supportsVirtualDisplay: false,
            availableModes: [config.mode])))
        try assertRoundTrip(.createDisplay(config))
        try assertRoundTrip(.displayConfiguration(config))
        try assertRoundTrip(.streamStart)
        try assertRoundTrip(.streamStop)
        try assertRoundTrip(.requestKeyframe)
        try assertRoundTrip(.networkStats(.init(fps: 60, bitrateBPS: 11_500_000,
                                                droppedFrameRatio: 0.002,
                                                decodeMillis: 5, renderMillis: 3)))
        try assertRoundTrip(.ping(.init(sequence: 7, sentAt: 123.456)))
        try assertRoundTrip(.pong(.init(sequence: 7, sentAt: 123.456)))
        try assertRoundTrip(.disconnect(.init(reason: "User quit")))
        try assertRoundTrip(.error(.init(code: "E_VERSION", message: "bad version")))
    }

    /// The `type` discriminator is the compatibility contract with older builds
    /// running on the iMac, so it is pinned by test rather than left implicit.
    func testWireDiscriminatorIsStable() throws {
        let data = try ControlCodec.encode(.ping(.init(sequence: 1, sentAt: 0)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "ping")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["sequence"] as? Int, 1)
    }

    func testPayloadlessMessagesOmitPayload() throws {
        let data = try ControlCodec.encode(.streamStart)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "streamStart")
        XCTAssertNil(json["payload"])
    }

    func testPongEchoesPingTimestampExactly() {
        let ping = ControlMessage.Ping(sequence: 42, sentAt: 987.654321)
        let pong = ControlMessage.Pong(echoing: ping)
        XCTAssertEqual(pong.sequence, ping.sequence)
        // RTT correctness depends on this being bit-identical, not merely close.
        XCTAssertEqual(pong.sentAt, ping.sentAt)
    }

    func testUnknownTypeFailsCleanly() {
        let data = Data(#"{"type":"somethingFromTheFuture"}"#.utf8)
        XCTAssertThrowsError(try ControlCodec.decode(data))
    }

    func testControlMessageSurvivesFullFramingRoundTrip() throws {
        let message = ControlMessage.clientCapabilities(sampleClientCapabilities())
        let framed = try ControlCodec.frame(message)
        let frames = try FrameParser().append(framed)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.channel, .control)
        XCTAssertEqual(try ControlCodec.decode(try XCTUnwrap(frames.first).payload), message)
    }
}
