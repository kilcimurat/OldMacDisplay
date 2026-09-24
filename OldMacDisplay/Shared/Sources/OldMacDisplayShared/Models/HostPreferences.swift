import Foundation

/// What the user picked in the Host UI. `auto` everywhere means "let the
/// negotiator decide from the Receiver's reported hardware".
public struct HostPreferences: Equatable {
    public enum Resolution: Equatable {
        case auto
        case fixed(width: Int, height: Int)
        /// Match the Receiver's own panel resolution.
        case native
    }

    public enum FrameRate: Equatable {
        case auto
        case fixed(Int)
    }

    public enum Codec: Equatable {
        case auto
        case forced(VideoCodec)
    }

    public var resolution: Resolution
    public var frameRate: FrameRate
    public var quality: QualityPreset
    public var codec: Codec

    public init(resolution: Resolution = .auto,
                frameRate: FrameRate = .auto,
                quality: QualityPreset = .balanced,
                codec: Codec = .auto) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.quality = quality
        self.codec = codec
    }

    public static let `default` = HostPreferences()
}
