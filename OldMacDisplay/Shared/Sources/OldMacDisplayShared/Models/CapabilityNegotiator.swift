import Foundation

/// Turns (Receiver capabilities + Host capabilities + user preferences) into the
/// concrete `SessionConfiguration` the stream will use.
///
/// This is deliberately pure so the whole of Phase 5's decision logic is covered
/// by unit tests that need neither a second Mac nor a virtual display.
public enum CapabilityNegotiator {

    /// Modes the Host is willing to create a virtual display at, best first.
    /// Explicitly excludes 4K/5K: the target is a 2013 iMac over gigabit.
    public static let preferredModeLadder: [(width: Int, height: Int)] = [
        (1920, 1080),
        (2560, 1440),
        (1680, 1050),
        (1440, 900),
        (1280, 800)
    ]

    public static func negotiate(client: ClientCapabilities,
                                 server: ServerCapabilities,
                                 preferences: HostPreferences) -> SessionConfiguration {
        let codec = chooseCodec(client: client, server: server, preference: preferences.codec)
        let mode = chooseMode(client: client, server: server, preference: preferences.resolution,
                              frameRate: preferences.frameRate)
        let bitrate = chooseBitrate(mode: mode, codec: codec,
                                    quality: preferences.quality,
                                    network: client.activeNetworkType)
        return SessionConfiguration(mode: mode, codec: codec, targetBitrateBPS: bitrate)
    }

    // MARK: - Codec

    /// H.264 is the compatibility floor and is never negotiated away. HEVC is
    /// only selected when BOTH ends report hardware support — a 2013 iMac has no
    /// HEVC decode block, so in practice this resolves to H.264 for our hardware.
    static func chooseCodec(client: ClientCapabilities,
                            server: ServerCapabilities,
                            preference: HostPreferences.Codec) -> VideoCodec {
        let hevcPossible = client.hevcHardwareDecode
            && server.hevcHardwareEncode
            && server.supportedCodecs.contains(.hevc)

        switch preference {
        case .forced(.hevc):
            // An explicit request still loses to missing hardware: falling back
            // beats a black screen on the iMac.
            return hevcPossible ? .hevc : .h264
        case .forced(.h264):
            return .h264
        case .auto:
            return hevcPossible ? .hevc : .h264
        }
    }

    // MARK: - Resolution

    static func chooseMode(client: ClientCapabilities,
                           server: ServerCapabilities,
                           preference: HostPreferences.Resolution,
                           frameRate: HostPreferences.FrameRate) -> DisplayMode {
        let fps = chooseFrameRate(client: client, preference: frameRate)

        switch preference {
        case .fixed(let width, let height):
            return DisplayMode(width: width, height: height, refreshRate: fps)

        case .native:
            return DisplayMode(width: client.displayWidth,
                               height: client.displayHeight,
                               refreshRate: fps)

        case .auto:
            // Largest laddered mode that fits inside the Receiver's panel, so the
            // image is never downscaled on the weaker machine. Falls back to the
            // panel's own size if even the smallest rung is too big.
            //
            // Capped on a wireless link. Measured on a 2013 iMac over Wi-Fi,
            // picking the panel's full 2560x1440 at 60 fps produced badly
            // lagging video: it is roughly 1.8x the pixels of 1080p, on a link
            // whose latency spikes to 640 ms, decoded by a 2013 GPU. 1080p is
            // the honest default there; Ethernet lifts the cap.
            let ceiling = autoResolutionCeiling(for: client)
            let fitting = preferredModeLadder.filter {
                $0.width <= client.displayWidth && $0.height <= client.displayHeight
                    && $0.width * $0.height <= ceiling
            }
            let best = fitting.max { lhs, rhs in
                (lhs.width * lhs.height) < (rhs.width * rhs.height)
            }
            guard let chosen = best else {
                return DisplayMode(width: client.displayWidth,
                                   height: client.displayHeight,
                                   refreshRate: fps)
            }
            return DisplayMode(width: chosen.width, height: chosen.height, refreshRate: fps)
        }
    }

    /// Largest pixel count `auto` will negotiate for this client.
    ///
    /// Only wired links get the full ladder. This is a deliberate policy choice
    /// rather than a hardware probe: link type is the one thing that reliably
    /// predicts whether a high-resolution stream will actually arrive on time.
    static func autoResolutionCeiling(for client: ClientCapabilities) -> Int {
        switch client.activeNetworkType {
        case .ethernet:
            return Int.max
        case .wifi, .other, .unknown:
            return 1920 * 1080
        }
    }

    static func chooseFrameRate(client: ClientCapabilities,
                                preference: HostPreferences.FrameRate) -> Int {
        switch preference {
        case .fixed(let fps):
            return clampFPS(fps)
        case .auto:
            // Never promise more than the Receiver said it wants.
            return clampFPS(client.preferredFPS)
        }
    }

    private static func clampFPS(_ fps: Int) -> Int {
        Swift.min(Swift.max(fps, 24), 60)
    }

    // MARK: - Bitrate

    /// Starting bitrate. The encoder adapts from here at runtime; this only has
    /// to be a sane opening bid.
    static func chooseBitrate(mode: DisplayMode,
                              codec: VideoCodec,
                              quality: QualityPreset,
                              network: NetworkType) -> Int {
        // Bits per pixel per frame. Desktop/IDE content is mostly static with
        // sharp text, so these sit above what a video-playback tuning would use.
        let bitsPerPixel: Double
        switch quality {
        case .performance: bitsPerPixel = 0.05
        case .balanced:    bitsPerPixel = 0.08
        case .quality:     bitsPerPixel = 0.12
        }

        let pixels = Double(mode.width * mode.height)
        var bitrate = pixels * Double(mode.refreshRate) * bitsPerPixel

        // HEVC reaches equivalent quality at roughly 60-70% of H.264's bitrate.
        if codec == .hevc { bitrate *= 0.65 }

        // Wi-Fi shares airtime and suffers under bursts; wired gigabit does not.
        let ceiling: Double
        switch network {
        case .ethernet:        ceiling = 40_000_000
        case .wifi:            ceiling = 15_000_000
        case .other, .unknown: ceiling = 12_000_000
        }
        if network != .ethernet { bitrate *= 0.7 }

        return Int(Swift.min(Swift.max(bitrate, 2_000_000), ceiling))
    }
}
