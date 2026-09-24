import XCTest
@testable import OldMacDisplayShared

final class VideoPacketTests: XCTestCase {

    func testAccessUnitRoundTrip() throws {
        let bitstream = Data((0..<4096).map { UInt8($0 % 256) })
        let packet = VideoPacket(kind: .accessUnit,
                                 isKeyframe: true,
                                 nalUnitHeaderLength: 4,
                                 presentationTimeMicros: 1_234_567_890_123,
                                 encodeDurationMicros: 4_321,
                                 payload: bitstream)
        XCTAssertEqual(try VideoPacket.decode(packet.encode()), packet)
    }

    /// Scatter-gather sends put the header and payload on the wire as separate
    /// buffers; what the peer reads back must equal the single-buffer form.
    func testEncodedPartsConcatenateToEncode() {
        let packet = VideoPacket(kind: .accessUnit, isKeyframe: true,
                                 presentationTimeMicros: 42, encodeDurationMicros: 7,
                                 payload: Data(repeating: 0xCD, count: 300))
        let parts = packet.encodedParts()
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].count, VideoPacket.headerLength)
        XCTAssertEqual(parts[0] + parts[1], packet.encode())
    }

    /// Decoding from a slice with a non-zero start index (what a parser or an
    /// exact-length socket read hands over) must not read from offset zero.
    func testDecodeFromSliceWithNonZeroStartIndex() throws {
        let packet = VideoPacket(kind: .accessUnit, isKeyframe: false,
                                 presentationTimeMicros: 99, payload: Data([9, 8, 7]))
        var buffer = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        buffer.append(packet.encode())
        let slice = buffer[5...]
        XCTAssertNotEqual(slice.startIndex, 0)
        let decoded = try VideoPacket.decode(slice)
        XCTAssertEqual(decoded, packet)
        XCTAssertEqual(Array(decoded.payload), [9, 8, 7])
        // The payload is itself a slice; consumers must index relative to it.
        XCTAssertEqual(decoded.payload[decoded.payload.startIndex], 9)
    }

    func testHeaderIsExactlySixteenBytes() {
        let packet = VideoPacket(kind: .accessUnit, payload: Data([1, 2, 3]))
        XCTAssertEqual(packet.encode().count, VideoPacket.headerLength + 3)
    }

    func testKeyframeFlagSurvives() throws {
        for keyframe in [true, false] {
            let packet = VideoPacket(kind: .accessUnit, isKeyframe: keyframe, payload: Data([0]))
            XCTAssertEqual(try VideoPacket.decode(packet.encode()).isKeyframe, keyframe)
        }
    }

    /// 64-bit microsecond timestamps must not lose precision; latency
    /// measurement depends on the exact value coming back.
    func testLargeTimestampsArePreserved() throws {
        let packet = VideoPacket(kind: .accessUnit,
                                 presentationTimeMicros: UInt64.max - 1,
                                 payload: Data())
        XCTAssertEqual(try VideoPacket.decode(packet.encode()).presentationTimeMicros,
                       UInt64.max - 1)
    }

    func testTruncatedHeaderThrows() {
        XCTAssertThrowsError(try VideoPacket.decode(Data([0, 0, 0]))) { error in
            XCTAssertEqual(error as? VideoPacketError, .truncated)
        }
    }

    func testUnknownKindThrows() {
        var data = Data([9])
        data.append(Data(repeating: 0, count: 15))
        XCTAssertThrowsError(try VideoPacket.decode(data)) { error in
            XCTAssertEqual(error as? VideoPacketError, .unknownKind(9))
        }
    }

    /// The exact path a real stream takes: packet -> frame -> TCP -> frame -> packet.
    func testVideoPacketThroughFullWireFraming() throws {
        let original = VideoPacket(kind: .accessUnit, isKeyframe: true,
                                   presentationTimeMicros: 999,
                                   payload: Data(repeating: 0xAB, count: 1500))
        let wire = try WireFormat.encode(OMDFrame(channel: .video, payload: original.encode()))

        let parser = FrameParser()
        var frames: [OMDFrame] = []
        // Split mid-packet to prove reassembly works for large video frames.
        frames += try parser.append(wire.prefix(700))
        XCTAssertTrue(frames.isEmpty)
        frames += try parser.append(wire.suffix(from: 700))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].channel, .video)
        XCTAssertEqual(try VideoPacket.decode(frames[0].payload), original)
    }
}

final class ParameterSetsTests: XCTestCase {

    func testH264ParameterSetsRoundTrip() throws {
        let sps = Data([0x67, 0x42, 0x00, 0x1E])
        let pps = Data([0x68, 0xCE, 0x38, 0x80])
        XCTAssertEqual(try ParameterSets.decode(ParameterSets.encode([sps, pps])), [sps, pps])
    }

    func testHEVCThreeParameterSetsRoundTrip() throws {
        let sets = [Data([0x40, 0x01]), Data([0x42, 0x01, 0x02]), Data([0x44, 0x01])]
        XCTAssertEqual(try ParameterSets.decode(ParameterSets.encode(sets)), sets)
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try ParameterSets.decode(Data()))
    }

    /// A truncated parameter-set blob must throw rather than read past the end.
    func testTruncatedPayloadThrows() {
        var data = ParameterSets.encode([Data([1, 2, 3, 4])])
        data.removeLast(2)
        XCTAssertThrowsError(try ParameterSets.decode(data)) { error in
            XCTAssertEqual(error as? VideoPacketError, .malformedParameterSets)
        }
    }

    func testDeclaredCountLargerThanDataThrows() {
        var data = Data([5]) // claims 5 sets
        data.append(contentsOf: [0, 0, 0, 1, 0xAA]) // provides 1
        XCTAssertThrowsError(try ParameterSets.decode(data))
    }
}
