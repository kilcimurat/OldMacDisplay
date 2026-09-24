import Foundation

/// A single framed unit on the wire.
public struct OMDFrame: Equatable {
    public let channel: OMDChannel
    public let flags: UInt8
    public let payload: Data

    public init(channel: OMDChannel, flags: UInt8 = 0, payload: Data) {
        self.channel = channel
        self.flags = flags
        self.payload = payload
    }
}

public enum WireFormatError: Error, Equatable {
    case badMagic
    case unsupportedVersion(UInt8)
    case unknownChannel(UInt8)
    case payloadTooLarge(UInt32)
    case truncatedHeader
}

/// Binary framing for every byte that crosses the network.
///
/// Layout (12-byte header, big-endian):
///
///     0  ..< 4   magic  "OMDS"
///     4          protocol version (UInt8)
///     5          channel          (UInt8)
///     6          flags            (UInt8)
///     7          reserved         (UInt8, must be 0)
///     8  ..< 12  payload length   (UInt32)
///     12 ..<     payload
///
/// Control payloads are JSON (see `ControlMessage`); video/audio payloads will be
/// raw compressed bitstreams, never re-encoded or Base64'd.
public enum WireFormat {
    public static let magic: [UInt8] = [0x4F, 0x4D, 0x44, 0x53] // "OMDS"
    public static let headerLength = 12

    public static func encode(_ frame: OMDFrame) throws -> Data {
        var out = try encodeHeader(channel: frame.channel, flags: frame.flags,
                                   payloadLength: frame.payload.count)
        out.append(frame.payload)
        return out
    }

    /// Just the 12-byte header, so a transport can send it and the payload as
    /// separate buffers instead of concatenating them into a fresh copy.
    public static func encodeHeader(channel: OMDChannel, flags: UInt8 = 0,
                                    payloadLength: Int) throws -> Data {
        guard payloadLength >= 0, payloadLength <= Int(OMDProtocol.maxPayloadLength) else {
            throw WireFormatError.payloadTooLarge(UInt32(clamping: payloadLength))
        }
        let length = UInt32(payloadLength)
        var out = Data(capacity: headerLength + payloadLength)
        out.append(contentsOf: magic)
        out.append(OMDProtocol.version)
        out.append(channel.rawValue)
        out.append(flags)
        out.append(0) // reserved
        out.append(contentsOf: bigEndianBytes(length))
        return out
    }

    /// Parsed header fields, used by the incremental parser and by transports
    /// that read a header and then exactly its payload.
    public struct Header: Equatable {
        public let channel: OMDChannel
        public let flags: UInt8
        public let payloadLength: UInt32
    }

    public static func decodeHeader(_ data: Data) throws -> Header {
        guard data.count >= headerLength else { throw WireFormatError.truncatedHeader }
        // `data` may be a slice with a non-zero startIndex, so index relative to it.
        let base = data.startIndex
        guard data[base] == magic[0], data[base + 1] == magic[1],
              data[base + 2] == magic[2], data[base + 3] == magic[3] else {
            throw WireFormatError.badMagic
        }
        let version = data[base + 4]
        guard version == OMDProtocol.version else {
            throw WireFormatError.unsupportedVersion(version)
        }
        let rawChannel = data[base + 5]
        guard let channel = OMDChannel(rawValue: rawChannel) else {
            throw WireFormatError.unknownChannel(rawChannel)
        }
        let flags = data[base + 6]
        let length = (UInt32(data[base + 8]) << 24)
            | (UInt32(data[base + 9]) << 16)
            | (UInt32(data[base + 10]) << 8)
            | UInt32(data[base + 11])
        guard length <= OMDProtocol.maxPayloadLength else {
            throw WireFormatError.payloadTooLarge(length)
        }
        return Header(channel: channel, flags: flags, payloadLength: length)
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF),
         UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF),
         UInt8(value & 0xFF)]
    }
}

/// Accumulates bytes arriving from the network and emits complete frames.
///
/// TCP gives no message boundaries, so every receive callback feeds its bytes in
/// here and drains whatever whole frames became available.
public final class FrameParser {
    private var buffer = Data()

    public init() {}

    /// Appends newly received bytes and returns every frame that is now complete.
    /// Throws on a malformed stream; the caller should tear the connection down
    /// rather than attempt resynchronisation.
    public func append(_ data: Data) throws -> [OMDFrame] {
        buffer.append(data)
        var frames: [OMDFrame] = []

        while true {
            guard buffer.count >= WireFormat.headerLength else { break }
            let header = try WireFormat.decodeHeader(buffer)
            let total = WireFormat.headerLength + Int(header.payloadLength)
            guard buffer.count >= total else { break }

            let payloadStart = buffer.startIndex + WireFormat.headerLength
            let payloadEnd = buffer.startIndex + total
            // Re-base the slice so downstream code can index from 0.
            let payload = Data(buffer[payloadStart..<payloadEnd])
            frames.append(OMDFrame(channel: header.channel, flags: header.flags, payload: payload))

            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        }
        return frames
    }

    /// Bytes currently held pending completion of a frame. Exposed for tests and
    /// diagnostics.
    public var bufferedByteCount: Int { buffer.count }

    public func reset() { buffer.removeAll(keepingCapacity: true) }
}
