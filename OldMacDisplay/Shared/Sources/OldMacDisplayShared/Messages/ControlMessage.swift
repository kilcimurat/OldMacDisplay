import Foundation

/// Every control-channel message in protocol version 2.
///
/// The full message set from the design is declared up front so the protocol is
/// stable. Unknown/unimplemented cases decode fine and are simply ignored by
/// the current handlers.
///
/// Encoding is JSON with an explicit `type` discriminator — never Swift object
/// serialisation (`NSKeyedArchiver`/`Codable` default enum layout), so the wire
/// shape stays readable, versionable and implementable by a non-Swift client.
public enum ControlMessage: Equatable {
    case hello(Hello)
    case clientCapabilities(ClientCapabilities)
    case serverCapabilities(ServerCapabilities)
    case createDisplay(SessionConfiguration)
    case displayConfiguration(SessionConfiguration)
    case streamStart
    case streamStop
    case requestKeyframe
    case videoConfiguration(VideoConfiguration)
    case networkStats(NetworkStats)
    case ping(Ping)
    case pong(Pong)
    case disconnect(Disconnect)
    case error(ProtocolError)
    /// Sent as the first frame on a second TCP connection to bind it to an
    /// existing session as the video carrier.
    case attachVideo(AttachVideo)
    /// Pointer position and shape on the virtual display, sent instead of
    /// baking the cursor into the video.
    case cursor(CursorUpdate)

    // MARK: - Payloads

    public struct Hello: Codable, Equatable {
        public let protocolVersion: Int
        public let device: DeviceInfo
        /// Set by the Host in its reply. The Receiver presents it on a second
        /// connection (`attachVideo`) so the Host can pair the two.
        public let sessionToken: String?
        public init(protocolVersion: Int = Int(OMDProtocol.version),
                    device: DeviceInfo,
                    sessionToken: String? = nil) {
            self.protocolVersion = protocolVersion
            self.device = device
            self.sessionToken = sessionToken
        }
    }

    public struct AttachVideo: Codable, Equatable {
        public let sessionToken: String
        public init(sessionToken: String) { self.sessionToken = sessionToken }
    }

    /// Where the pointer is on the streamed display, normalised to 0...1 so the
    /// Receiver can place it regardless of how the video is scaled.
    ///
    /// `imagePNG` is only present when the cursor shape changed; the Receiver
    /// keeps the last image it was given. `hotspot` and `imageSize` are in
    /// points of the encoded display.
    public struct CursorUpdate: Codable, Equatable {
        public let x: Double
        public let y: Double
        public let visible: Bool
        public let imagePNG: Data?
        public let hotspotX: Double?
        public let hotspotY: Double?
        public let imageWidth: Double?
        public let imageHeight: Double?
        public init(x: Double, y: Double, visible: Bool,
                    imagePNG: Data? = nil,
                    hotspotX: Double? = nil, hotspotY: Double? = nil,
                    imageWidth: Double? = nil, imageHeight: Double? = nil) {
            self.x = x
            self.y = y
            self.visible = visible
            self.imagePNG = imagePNG
            self.hotspotX = hotspotX
            self.hotspotY = hotspotY
            self.imageWidth = imageWidth
            self.imageHeight = imageHeight
        }
    }

    /// `sentAt` is the sender's monotonic clock in seconds. The value is echoed
    /// verbatim in the `Pong` so RTT needs no clock synchronisation between the
    /// two machines.
    public struct Ping: Codable, Equatable {
        public let sequence: UInt32
        public let sentAt: Double
        public init(sequence: UInt32, sentAt: Double) {
            self.sequence = sequence
            self.sentAt = sentAt
        }
    }

    /// `receivedAt` is the responder's own monotonic clock when the ping
    /// arrived. Together with the RTT it lets the pinger estimate the offset
    /// between the two clocks (see `ClockOffsetEstimator`), which is what makes
    /// one-way, capture-to-display latency measurable.
    public struct Pong: Codable, Equatable {
        public let sequence: UInt32
        public let sentAt: Double
        public let receivedAt: Double?
        public init(sequence: UInt32, sentAt: Double, receivedAt: Double? = nil) {
            self.sequence = sequence
            self.sentAt = sentAt
            self.receivedAt = receivedAt
        }
        public init(echoing ping: Ping, receivedAt: Double? = nil) {
            self.sequence = ping.sequence
            self.sentAt = ping.sentAt
            self.receivedAt = receivedAt
        }
    }

    /// Describes the bitstream that is about to arrive on the video channel.
    /// Distinct from `displayConfiguration`: the encoded size can differ from
    /// the display mode (macroblock alignment), and the decoder needs the
    /// encoded size, not the desktop size.
    public struct VideoConfiguration: Codable, Equatable {
        public let codec: VideoCodec
        public let encodedWidth: Int
        public let encodedHeight: Int
        public let frameRate: Int
        public init(codec: VideoCodec, encodedWidth: Int, encodedHeight: Int, frameRate: Int) {
            self.codec = codec
            self.encodedWidth = encodedWidth
            self.encodedHeight = encodedHeight
            self.frameRate = frameRate
        }
    }

    public struct NetworkStats: Codable, Equatable {
        public let fps: Double
        public let bitrateBPS: Int
        public let droppedFrameRatio: Double
        public let decodeMillis: Double
        public let renderMillis: Double
        /// How much later than its steady-state schedule the worst frame of the
        /// window arrived. Clock-independent; the Host's congestion signal.
        public let queueingDelayMillis: Double?
        /// Capture-to-enqueue latency, when the clocks have been aligned.
        public let endToEndMillis: Double?
        public init(fps: Double, bitrateBPS: Int, droppedFrameRatio: Double,
                    decodeMillis: Double, renderMillis: Double,
                    queueingDelayMillis: Double? = nil,
                    endToEndMillis: Double? = nil) {
            self.fps = fps
            self.bitrateBPS = bitrateBPS
            self.droppedFrameRatio = droppedFrameRatio
            self.decodeMillis = decodeMillis
            self.renderMillis = renderMillis
            self.queueingDelayMillis = queueingDelayMillis
            self.endToEndMillis = endToEndMillis
        }
    }

    public struct Disconnect: Codable, Equatable {
        public let reason: String
        public init(reason: String) { self.reason = reason }
    }

    public struct ProtocolError: Codable, Equatable {
        public let code: String
        public let message: String
        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }
}

// MARK: - Codable with an explicit discriminator

extension ControlMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    /// Wire names. Kept as explicit strings so renaming a Swift case never
    /// silently breaks compatibility with an older build on the iMac.
    public enum Kind: String, Codable {
        case hello
        case clientCapabilities
        case serverCapabilities
        case createDisplay
        case displayConfiguration
        case streamStart
        case streamStop
        case requestKeyframe
        case videoConfiguration
        case networkStats
        case ping
        case pong
        case disconnect
        case error
        case attachVideo
        case cursor
    }

    public var kind: Kind {
        switch self {
        case .hello: return .hello
        case .clientCapabilities: return .clientCapabilities
        case .serverCapabilities: return .serverCapabilities
        case .createDisplay: return .createDisplay
        case .displayConfiguration: return .displayConfiguration
        case .streamStart: return .streamStart
        case .streamStop: return .streamStop
        case .requestKeyframe: return .requestKeyframe
        case .videoConfiguration: return .videoConfiguration
        case .networkStats: return .networkStats
        case .ping: return .ping
        case .pong: return .pong
        case .disconnect: return .disconnect
        case .error: return .error
        case .attachVideo: return .attachVideo
        case .cursor: return .cursor
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case .hello(let v):                 try container.encode(v, forKey: .payload)
        case .clientCapabilities(let v):    try container.encode(v, forKey: .payload)
        case .serverCapabilities(let v):    try container.encode(v, forKey: .payload)
        case .createDisplay(let v):         try container.encode(v, forKey: .payload)
        case .displayConfiguration(let v):  try container.encode(v, forKey: .payload)
        case .videoConfiguration(let v):    try container.encode(v, forKey: .payload)
        case .networkStats(let v):          try container.encode(v, forKey: .payload)
        case .ping(let v):                  try container.encode(v, forKey: .payload)
        case .pong(let v):                  try container.encode(v, forKey: .payload)
        case .disconnect(let v):            try container.encode(v, forKey: .payload)
        case .error(let v):                 try container.encode(v, forKey: .payload)
        case .attachVideo(let v):           try container.encode(v, forKey: .payload)
        case .cursor(let v):                try container.encode(v, forKey: .payload)
        case .streamStart, .streamStop, .requestKeyframe:
            break // no payload
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .hello:
            self = .hello(try container.decode(Hello.self, forKey: .payload))
        case .clientCapabilities:
            self = .clientCapabilities(try container.decode(ClientCapabilities.self, forKey: .payload))
        case .serverCapabilities:
            self = .serverCapabilities(try container.decode(ServerCapabilities.self, forKey: .payload))
        case .createDisplay:
            self = .createDisplay(try container.decode(SessionConfiguration.self, forKey: .payload))
        case .displayConfiguration:
            self = .displayConfiguration(try container.decode(SessionConfiguration.self, forKey: .payload))
        case .videoConfiguration:
            self = .videoConfiguration(try container.decode(VideoConfiguration.self, forKey: .payload))
        case .networkStats:
            self = .networkStats(try container.decode(NetworkStats.self, forKey: .payload))
        case .ping:
            self = .ping(try container.decode(Ping.self, forKey: .payload))
        case .pong:
            self = .pong(try container.decode(Pong.self, forKey: .payload))
        case .disconnect:
            self = .disconnect(try container.decode(Disconnect.self, forKey: .payload))
        case .error:
            self = .error(try container.decode(ProtocolError.self, forKey: .payload))
        case .attachVideo:
            self = .attachVideo(try container.decode(AttachVideo.self, forKey: .payload))
        case .cursor:
            self = .cursor(try container.decode(CursorUpdate.self, forKey: .payload))
        case .streamStart:     self = .streamStart
        case .streamStop:      self = .streamStop
        case .requestKeyframe: self = .requestKeyframe
        }
    }
}

// MARK: - Control channel codec

public enum ControlCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encode(_ message: ControlMessage) throws -> Data {
        try encoder.encode(message)
    }

    public static func decode(_ data: Data) throws -> ControlMessage {
        try decoder.decode(ControlMessage.self, from: data)
    }

    /// Convenience: wrap a control message in a control-channel wire frame.
    public static func frame(_ message: ControlMessage) throws -> Data {
        try WireFormat.encode(OMDFrame(channel: .control, payload: encode(message)))
    }
}
