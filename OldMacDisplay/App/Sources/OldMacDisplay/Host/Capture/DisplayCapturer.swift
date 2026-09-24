import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import OldMacDisplayShared

/// Captures a single macOS display with ScreenCaptureKit.
///
/// Phase 2 captures the physical main display. Phase 3 will point the same
/// filter at the virtual display instead — that is the only change needed here,
/// which is why the display is a parameter rather than being resolved inside.
@available(macOS 13.0, *)
final class DisplayCapturer: NSObject, SCStreamOutput, SCStreamDelegate {

    struct Configuration {
        var width: Int
        var height: Int
        var frameRate: Int
    }

    enum CaptureError: LocalizedError {
        case noDisplaysFound
        case displayNotFound(CGDirectDisplayID)
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noDisplaysFound:
                return "No displays available to capture."
            case .displayNotFound(let id):
                return "Display \(id) is no longer available."
            case .permissionDenied:
                return "Screen Recording permission is required. Grant it in System Settings › Privacy & Security › Screen Recording, then restart OldMacDisplay Host."
            }
        }
    }

    /// Delivers captured frames on the capture queue.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.oldmacdisplay.host.capture",
                                      qos: .userInteractive)
    private let log = Log(.capture)

    /// Recognises the Screen Recording TCC denial and replaces it with an
    /// actionable message. ScreenCaptureKit's own text ("The user declined TCCs
    /// for application, window, display capture") tells the user nothing about
    /// what to do next.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamError.errorDomain,
           nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return CaptureError.permissionDenied.errorDescription ?? nsError.localizedDescription
        }
        return error.localizedDescription
    }

    /// Opens the Screen Recording pane so the user does not have to hunt for it.
    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Resolves the display to capture. `nil` picks the main display.
    ///
    /// Callback-based rather than `async`: the Receiver half of this app has to
    /// run on Catalina, which ships no Swift Concurrency runtime, so the whole
    /// binary stays concurrency-free.
    static func resolveDisplay(id: CGDirectDisplayID?,
                               attemptsLeft: Int = 10,
                               completion: @escaping (Result<SCDisplay, Error>) -> Void) {
        // `excludingDesktopWindows:false` keeps wallpaper and desktop icons.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
            content, error in
            // A virtual display that CoreGraphics already lists can take a
            // moment longer to show up in ScreenCaptureKit's content, so a
            // miss right after creating one is retried for ~2 s.
            func retryOrFail(_ failure: Error) {
                guard attemptsLeft > 1 else {
                    completion(.failure(failure))
                    return
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
                    resolveDisplay(id: id, attemptsLeft: attemptsLeft - 1, completion: completion)
                }
            }

            if let error = error {
                retryOrFail(error)
                return
            }
            guard let content = content, !content.displays.isEmpty else {
                retryOrFail(CaptureError.noDisplaysFound)
                return
            }
            if let id = id {
                guard let match = content.displays.first(where: { $0.displayID == id }) else {
                    retryOrFail(CaptureError.displayNotFound(id))
                    return
                }
                completion(.success(match))
                return
            }
            let mainID = CGMainDisplayID()
            completion(.success(content.displays.first { $0.displayID == mainID }
                                ?? content.displays[0]))
        }
    }

    func start(display: SCDisplay, configuration: Configuration) throws {
        stop()

        // Capture only this display, excluding nothing on it. Phase 3 will pass
        // the virtual display here so the physical screen is never captured.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = configuration.width
        streamConfig.height = configuration.height
        streamConfig.minimumFrameInterval = CMTime(value: 1,
                                                   timescale: CMTimeScale(configuration.frameRate))
        // Encoder-native format: no colour conversion between capture and
        // VideoToolbox, which keeps the path close to zero-copy.
        streamConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // The cursor is not baked into the video. With it in, every mouse
        // movement over an otherwise static desktop forced a full re-encode;
        // instead `CursorTracker` sends the pointer out of band and the
        // Receiver draws it, so a still screen costs nothing on the wire.
        streamConfig.showsCursor = false
        // A short queue is deliberate: if the encoder falls behind we want
        // ScreenCaptureKit to drop frames rather than build a latency backlog.
        streamConfig.queueDepth = 3
        streamConfig.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream

        log.info("Starting capture of display \(display.displayID) at \(configuration.width)x\(configuration.height) @\(configuration.frameRate)")

        stream.startCapture { [weak self] error in
            guard let self = self, let error = error else { return }
            self.log.failure("startCapture", error)
            self.onError?(error)
        }
    }

    func stop() {
        guard let stream = stream else { return }
        self.stream = nil
        stream.stopCapture { [weak self] error in
            if let error = error { self?.log.failure("stopCapture", error) }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // ScreenCaptureKit emits frames even when nothing changed, tagged with a
        // status. Only `.complete` carries new pixels; forwarding the others
        // would waste encoder bandwidth re-encoding an identical screen.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusValue),
              status == .complete else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.failure("Capture stopped", error)
        onError?(error)
    }
}
