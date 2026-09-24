import Foundation

/// Binary payload carried on `OMDChannel.video`.
///
/// Sits *inside* an `OMDFrame`, so the outer wire format handles length framing
/// and this header only describes the media. Compressed bitstream bytes are
/// passed through exactly as VideoToolbox produced them — never re-encoded,
/// never Base64'd.
///
/// Header layout (16 bytes, big-endian):
///
///     0        kind                (UInt8)  0 = parameterSets, 1 = accessUnit
///     1        flags               (UInt8)  bit0 = keyframe
///     2        nalUnitHeaderLength (UInt8)  AVCC length prefix size, 1/2/4
///     3        reserved            (UInt8)
///     4  ..< 12 presentationTime   (UInt64) microseconds
///     12 ..< 16 encodeDuration     (UInt32) microseconds, for latency stats
public struct VideoPacket: Equatable {
    public enum Kind: UInt8 {
        /// SPS/PPS (H.264) or VPS/SPS/PPS (HEVC). Sent before the first frame
        /// and repeated with every keyframe so a Receiver that joins late, or
        /// reconnects, can rebuild its decoder without a round trip.
        case parameterSets = 0
        /// One compressed access unit (a single frame) in AVCC form.
        case accessUnit = 1
    }

    public static let headerLength = 16

    public var kind: Kind
    public var isKeyframe: Bool
    public var nalUnitHeaderLength: UInt8
    public var presentationTimeMicros: UInt64
    public var encodeDurationMicros: UInt32
    public var payload: Data

    public init(kind: Kind,
                isKeyframe: Bool = false,
                nalUnitHeaderLength: UInt8 = 4,
                presentationTimeMicros: UInt64 = 0,
                encodeDurationMicros: UInt32 = 0,
                payload: Data) {
        self.kind = kind
        self.isKeyframe = isKeyframe
        self.nalUnitHeaderLength = nalUnitHeaderLength
        self.presentationTimeMicros = presentationTimeMicros
        self.encodeDurationMicros = encodeDurationMicros
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(capacity: VideoPacket.headerLength + payload.count)
        out.append(kind.rawValue)
        out.append(isKeyframe ? 1 : 0)
        out.append(nalUnitHeaderLength)
        out.append(0) // reserved
        out.append(contentsOf: ByteOrder.bigEndian(presentationTimeMicros))
        out.append(contentsOf: ByteOrder.bigEndian(encodeDurationMicros))
        out.append(payload)
        return out
    }

    public static func decode(_ data: Data) throws -> VideoPacket {
        guard data.count >= headerLength else { throw VideoPacketError.truncated }
        let base = data.startIndex
        guard let kind = Kind(rawValue: data[base]) else {
            throw VideoPacketError.unknownKind(data[base])
        }
        return VideoPacket(
            kind: kind,
            isKeyframe: data[base + 1] & 0x01 != 0,
            nalUnitHeaderLength: data[base + 2],
            presentationTimeMicros: ByteOrder.readUInt64(data, at: base + 4),
            encodeDurationMicros: ByteOrder.readUInt32(data, at: base + 12),
            payload: Data(data[(base + headerLength)...]))
    }
}

public enum VideoPacketError: Error, Equatable {
    case truncated
    case unknownKind(UInt8)
    case malformedParameterSets
}

/// Serialises the codec parameter sets (SPS/PPS, or VPS/SPS/PPS) as the payload
/// of a `.parameterSets` packet.
///
///     count  (UInt8)
///     repeat: length (UInt32 BE) + bytes
public enum ParameterSets {
    public static func encode(_ sets: [Data]) -> Data {
        var out = Data()
        out.append(UInt8(min(sets.count, 255)))
        for set in sets.prefix(255) {
            out.append(contentsOf: ByteOrder.bigEndian(UInt32(set.count)))
            out.append(set)
        }
        return out
    }

    public static func decode(_ data: Data) throws -> [Data] {
        guard !data.isEmpty else { throw VideoPacketError.malformedParameterSets }
        var cursor = data.startIndex
        let count = Int(data[cursor])
        cursor += 1

        var sets: [Data] = []
        sets.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor + 4 <= data.endIndex else {
                throw VideoPacketError.malformedParameterSets
            }
            let length = Int(ByteOrder.readUInt32(data, at: cursor))
            cursor += 4
            guard length > 0, cursor + length <= data.endIndex else {
                throw VideoPacketError.malformedParameterSets
            }
            sets.append(Data(data[cursor..<(cursor + length)]))
            cursor += length
        }
        return sets
    }
}

/// Big-endian helpers shared by the binary payload formats.
enum ByteOrder {
    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func bigEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8((value >> UInt64($0 * 8)) & 0xFF) }
    }

    static func readUInt32(_ data: Data, at index: Data.Index) -> UInt32 {
        (UInt32(data[index]) << 24) | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8) | UInt32(data[index + 3])
    }

    static func readUInt64(_ data: Data, at index: Data.Index) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0..<8 { value = (value << 8) | UInt64(data[index + offset]) }
        return value
    }
}
