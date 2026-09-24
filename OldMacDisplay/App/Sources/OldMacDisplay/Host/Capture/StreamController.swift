import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import OldMacDisplayShared

/// Owns the capture → encode pipeline and hands packets to whoever is sending.
///
/// Knows nothing about the network, and the session knows nothing about
/// VideoToolbox; they meet through `onPacket` and `onConfiguration`.
@available(macOS 13.0, *)
final class StreamController {

    struct Stats: Equatable {
        var framesCaptured = 0
        var framesEncoded = 0
        var framesDropped = 0
        var measuredFPS: Double = 0
        var measuredBitrateBPS: Int = 0
        var averageEncodeMillis: Double = 0
    }

    /// Emitted before any video packet, so the Receiver can prepare its decoder.
    var onConfiguration: ((ControlMessage.VideoConfiguration) -> Void)?
    var onPacket: ((VideoPacket) -> Void)?
    var onError: ((String) -> Void)?
    var onStats: ((Stats) -> Void)?

    private(set) var isRunning = false
    private(set) var stats = Stats()

    private let capturer = DisplayCapturer()
    private var encoder: VideoEncoder?
    private var currentConfiguration: SessionConfiguration?
    private let log = Log(.capture)

    /// Serialises pipeline setup/teardown against frames arriving on the
    /// capture queue.
    private let lock = NSLock()

    // Rolling counters for the stats window.
    private var windowStart = MonotonicClock.now()
    private var windowBytes = 0
    private var windowFrames = 0
    private var windowEncodeMicros: UInt64 = 0

    // MARK: - Lifecycle

    /// Starts, or restarts with new settings, the capture and encode pipeline.
    func start(configuration: SessionConfiguration, displayID: CGDirectDisplayID? = nil) {
        // Restarting with identical settings would produce a visible black gap
        // for no benefit.
        if isRunning, currentConfiguration == configuration {
            log.info("Stream already running with these settings; not restarting")
            return
        }

        DisplayCapturer.resolveDisplay(id: displayID) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success(let display):
                    do {
                        try self.begin(configuration: configuration, display: display)
                    } catch {
                        self.log.failure("Starting stream", error)
                        self.onError?(DisplayCapturer.describe(error))
                    }
                case .failure(let error):
                    self.log.failure("Resolving display", error)
                    self.onError?(DisplayCapturer.describe(error))
                }
            }
        }
    }

    private func begin(configuration: SessionConfiguration, display: SCDisplay) throws {
        stopPipeline()

        lock.lock()
        defer { lock.unlock() }

        // ScreenCaptureKit hands back the display's pixel size; encode at the
        // negotiated mode, letting it scale, so the Receiver gets exactly what
        // it asked for.
        let width = configuration.mode.width
        let height = configuration.mode.height

        let encoder = try VideoEncoder(configuration: .init(
            codec: configuration.codec,
            width: width,
            height: height,
            frameRate: configuration.mode.refreshRate,
            bitrateBPS: configuration.targetBitrateBPS))

        encoder.onPacket = { [weak self] packet in
            guard let self else { return }
            self.record(packet)
            self.onPacket?(packet)
        }
        self.encoder = encoder
        self.currentConfiguration = configuration

        capturer.onFrame = { [weak self] pixelBuffer, time in
            self?.handleCaptured(pixelBuffer, at: time)
        }
        capturer.onError = { [weak self] error in
            self?.log.failure("Capture", error)
            self?.onError?(DisplayCapturer.describe(error))
        }

        try capturer.start(display: display,
                           configuration: .init(width: width, height: height,
                                                frameRate: configuration.mode.refreshRate))

        isRunning = true
        resetStats()

        onConfiguration?(.init(codec: configuration.codec,
                               encodedWidth: width,
                               encodedHeight: height,
                               frameRate: configuration.mode.refreshRate))
        log.info("Streaming \(configuration.mode) \(configuration.codec.rawValue)")
    }

    func stop() {
        stopPipeline()
        log.info("Stream stopped")
    }

    private func stopPipeline() {
        capturer.onFrame = nil
        capturer.stop()

        lock.lock()
        encoder?.invalidate()
        encoder = nil
        currentConfiguration = nil
        isRunning = false
        lock.unlock()
    }

    func requestKeyframe() {
        lock.lock()
        encoder?.requestKeyframe()
        lock.unlock()
    }

    func updateBitrate(_ bitrateBPS: Int) {
        lock.lock()
        encoder?.updateBitrate(bitrateBPS)
        lock.unlock()
    }

    // MARK: - Pipeline

    private func handleCaptured(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        guard let encoder = encoder else {
            lock.unlock()
            return
        }
        let forceKeyframe = encoder.consumeKeyframeRequest()
        lock.unlock()

        stats.framesCaptured += 1
        encoder.encode(pixelBuffer, presentationTime: time, forceKeyframe: forceKeyframe)
    }

    private func record(_ packet: VideoPacket) {
        guard packet.kind == .accessUnit else { return }
        stats.framesEncoded += 1
        windowFrames += 1
        windowBytes += packet.payload.count
        windowEncodeMicros += UInt64(packet.encodeDurationMicros)

        // Report once a second; more often would be noise in the UI.
        let now = MonotonicClock.now()
        let elapsed = now - windowStart
        guard elapsed >= 1.0 else { return }

        stats.measuredFPS = Double(windowFrames) / elapsed
        stats.measuredBitrateBPS = Int(Double(windowBytes * 8) / elapsed)
        stats.averageEncodeMillis = windowFrames > 0
            ? Double(windowEncodeMicros) / Double(windowFrames) / 1000.0
            : 0

        let snapshot = stats
        log.info(String(format: "capture/encode: %.1f fps, %.2f Mbps, encode %.2f ms",
                        snapshot.measuredFPS,
                        Double(snapshot.measuredBitrateBPS) / 1_000_000,
                        snapshot.averageEncodeMillis))
        onStats?(snapshot)

        windowStart = now
        windowFrames = 0
        windowBytes = 0
        windowEncodeMicros = 0
    }

    private func resetStats() {
        stats = Stats()
        windowStart = MonotonicClock.now()
        windowFrames = 0
        windowBytes = 0
        windowEncodeMicros = 0
    }
}
