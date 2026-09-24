import XCTest
@testable import OldMacDisplayShared

final class WireFormatTests: XCTestCase {

    func testRoundTripPreservesChannelFlagsAndPayload() throws {
        let payload = Data((0..<1024).map { UInt8($0 % 251) })
        let frame = OMDFrame(channel: .video, flags: 0x5A, payload: payload)

        let encoded = try WireFormat.encode(frame)
        XCTAssertEqual(encoded.count, WireFormat.headerLength + payload.count)

        let parser = FrameParser()
        let frames = try parser.append(encoded)
        XCTAssertEqual(frames, [frame])
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testHeaderLayoutIsExactlyAsDocumented() throws {
        let frame = OMDFrame(channel: .input, flags: 1, payload: Data([0xAA, 0xBB]))
        let encoded = try WireFormat.encode(frame)
        XCTAssertEqual(Array(encoded[0..<4]), WireFormat.magic)
        XCTAssertEqual(encoded[4], OMDProtocol.version)
        XCTAssertEqual(encoded[5], OMDChannel.input.rawValue)
        XCTAssertEqual(encoded[6], 1)
        XCTAssertEqual(encoded[7], 0, "reserved byte must be zero")
        XCTAssertEqual(Array(encoded[8..<12]), [0, 0, 0, 2], "big-endian length")
    }

    /// TCP delivers arbitrary chunks; the parser must not care where the splits
    /// land. This is the single most likely source of a "works on loopback,
    /// breaks over Ethernet" bug, so it is tested byte by byte.
    func testFramesReassembleAcrossArbitrarySplits() throws {
        let frames = [
            OMDFrame(channel: .control, payload: Data("first".utf8)),
            OMDFrame(channel: .video, payload: Data(repeating: 7, count: 300)),
            OMDFrame(channel: .audio, payload: Data())
        ]
        let stream = try frames.reduce(Data()) { $0 + (try WireFormat.encode($1)) }

        let parser = FrameParser()
        var received: [OMDFrame] = []
        for byte in stream {
            received += try parser.append(Data([byte]))
        }
        XCTAssertEqual(received, frames)
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testMultipleFramesInOneChunk() throws {
        let a = OMDFrame(channel: .control, payload: Data("a".utf8))
        let b = OMDFrame(channel: .control, payload: Data("b".utf8))
        let stream = try WireFormat.encode(a) + WireFormat.encode(b)
        XCTAssertEqual(try FrameParser().append(stream), [a, b])
    }

    func testEmptyPayloadIsValid() throws {
        let frame = OMDFrame(channel: .control, payload: Data())
        XCTAssertEqual(try FrameParser().append(try WireFormat.encode(frame)), [frame])
    }

    func testPartialHeaderIsBuffered() throws {
        let parser = FrameParser()
        XCTAssertEqual(try parser.append(Data(WireFormat.magic)), [])
        XCTAssertEqual(parser.bufferedByteCount, 4)
    }

    func testBadMagicThrows() {
        var bad = Data([0x00, 0x00, 0x00, 0x00, OMDProtocol.version, 0, 0, 0])
        bad.append(contentsOf: [0, 0, 0, 0])
        XCTAssertThrowsError(try FrameParser().append(bad)) { error in
            XCTAssertEqual(error as? WireFormatError, .badMagic)
        }
    }

    func testUnsupportedVersionThrows() {
        var bad = Data(WireFormat.magic)
        bad.append(contentsOf: [99, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try FrameParser().append(bad)) { error in
            XCTAssertEqual(error as? WireFormatError, .unsupportedVersion(99))
        }
    }

    func testUnknownChannelThrows() {
        var bad = Data(WireFormat.magic)
        bad.append(contentsOf: [OMDProtocol.version, 200, 0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try FrameParser().append(bad)) { error in
            XCTAssertEqual(error as? WireFormatError, .unknownChannel(200))
        }
    }

    /// A corrupt length field must not cause a multi-gigabyte allocation.
    func testOversizedLengthIsRejected() {
        var bad = Data(WireFormat.magic)
        bad.append(contentsOf: [OMDProtocol.version, 0, 0, 0])
        bad.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try FrameParser().append(bad)) { error in
            XCTAssertEqual(error as? WireFormatError, .payloadTooLarge(0xFFFFFFFF))
        }
    }
}
