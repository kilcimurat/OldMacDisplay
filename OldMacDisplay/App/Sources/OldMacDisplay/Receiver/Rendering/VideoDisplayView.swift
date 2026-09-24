import AppKit
import AVFoundation
import CoreMedia
import OldMacDisplayShared

/// Displays the incoming stream.
///
/// Backed by `AVSampleBufferDisplayLayer`, which decodes in hardware and
/// presents without an intermediate `CVPixelBuffer` copy in our code.
///
/// Why this rather than `VTDecompressionSession` + Metal for the first working
/// version:
///
/// * fewer moving parts — CoreMedia owns the decoder lifecycle, including
///   recovery after a format change
/// * no copies on our side; we hand it the `CMSampleBuffer` and it displays it
/// * available since macOS 10.8, so no Catalina risk
/// * combined with the `DisplayImmediately` attachment there is no presentation
///   queue, so latency is bounded at roughly one frame
///
/// What it costs: no direct decode timing, and no per-frame control over
/// dropping. Phase 4 can swap in an explicit `VTDecompressionSession` + Metal
/// renderer behind this same view if measurements justify it.
final class VideoDisplayView: NSView {

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let log = Log(.renderer)

    private(set) var framesDisplayed = 0
    private(set) var framesDropped = 0
    private var lastReport = MonotonicClock.now()
    private var framesSinceReport = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func setUp() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        // Aspect-fit inside a black field: the iMac's panel and the streamed
        // mode rarely share an aspect ratio exactly.
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    override func layout() {
        super.layout()
        // No implicit animation: the layer must follow a live resize exactly,
        // otherwise every window resize shows the video sliding into place.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    override var isFlipped: Bool { true }

    /// Enqueues one decoded-and-ready sample buffer for display.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // `.failed` happens after a decode error or a format change; the layer
        // will not recover on its own and must be flushed.
        if displayLayer.status == .failed {
            log.error("Display layer failed (\(displayLayer.error.map(String.init(describing:)) ?? "unknown")); flushing")
            displayLayer.flush()
            framesDropped += 1
            return
        }

        guard displayLayer.isReadyForMoreMediaData else {
            // Dropping beats queueing: a backlog would show up as growing lag
            // rather than a brief stutter.
            framesDropped += 1
            return
        }

        displayLayer.enqueue(sampleBuffer)
        framesDisplayed += 1
        reportIfDue()
    }

    /// One line a second, so a session on the iMac can be diagnosed from the
    /// unified log without attaching a debugger.
    private func reportIfDue() {
        framesSinceReport += 1
        let now = MonotonicClock.now()
        let elapsed = now - lastReport
        guard elapsed >= 1.0 else { return }
        log.info(String(format: "render: %.1f fps displayed (total %d, dropped %d)",
                        Double(framesSinceReport) / elapsed, framesDisplayed, framesDropped))
        lastReport = now
        framesSinceReport = 0
    }

    /// Clears the layer, e.g. on disconnect or before a resolution change.
    func flush() {
        displayLayer.flushAndRemoveImage()
    }

    func resetCounters() {
        framesDisplayed = 0
        framesDropped = 0
    }
}
