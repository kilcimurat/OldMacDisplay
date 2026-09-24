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
/// dropping. An explicit `VTDecompressionSession` + Metal renderer can be
/// swapped in behind this same view if measurements justify it.
///
/// `enqueue` is called on the network queue; `AVSampleBufferDisplayLayer` is
/// thread-safe for that, and the counters are guarded. Everything else is
/// main-thread AppKit.
final class VideoDisplayView: NSView {

    /// A frame had to be discarded, so the decoder's reference chain is
    /// broken until the next keyframe. Called on the enqueueing thread.
    var onFrameDropped: (() -> Void)?

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let cursorLayer = CALayer()
    private let log = Log(.renderer)

    private let counterLock = NSLock()
    private var _framesDisplayed = 0
    private var _framesDropped = 0
    private var lastReport = MonotonicClock.now()
    private var framesSinceReport = 0

    /// Encoded size of the stream, for mapping cursor coordinates onto the
    /// aspect-fitted video rectangle.
    private var videoSize = CGSize(width: 16, height: 9)
    private var cursorHotspot = CGPoint.zero
    private var cursorImageSize = CGSize(width: 16, height: 16)
    private var cursorPosition: CGPoint?

    var framesDisplayed: Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return _framesDisplayed
    }

    var framesDropped: Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return _framesDropped
    }

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

        // The pointer is drawn here, not in the video (see `CursorTracker`).
        cursorLayer.isHidden = true
        cursorLayer.anchorPoint = .zero
        cursorLayer.contentsGravity = .resize
        cursorLayer.magnificationFilter = .linear
        cursorLayer.zPosition = 1
        layer?.addSublayer(cursorLayer)
    }

    override func layout() {
        super.layout()
        // No implicit animation: the layer must follow a live resize exactly,
        // otherwise every window resize shows the video sliding into place.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        placeCursor()
        CATransaction.commit()
    }

    override var isFlipped: Bool { true }

    // MARK: - Video

    /// Enqueues one decoded-and-ready sample buffer for display. Any thread.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // `.failed` happens after a decode error or a format change; the layer
        // will not recover on its own and must be flushed.
        if displayLayer.status == .failed {
            log.error("Display layer failed (\(displayLayer.error.map(String.init(describing:)) ?? "unknown")); flushing")
            displayLayer.flush()
            recordDrop()
            return
        }

        guard displayLayer.isReadyForMoreMediaData else {
            // Dropping beats queueing: a backlog would show up as growing lag
            // rather than a brief stutter. But a dropped P-frame leaves every
            // following frame referencing something the decoder never saw, so
            // the Host is asked for an IDR.
            recordDrop()
            return
        }

        displayLayer.enqueue(sampleBuffer)

        counterLock.lock()
        _framesDisplayed += 1
        framesSinceReport += 1
        let now = MonotonicClock.now()
        let elapsed = now - lastReport
        var line: String?
        if elapsed >= 1.0 {
            // One line a second, so a session on the iMac can be diagnosed
            // from the unified log without attaching a debugger.
            line = String(format: "render: %.1f fps displayed (total %d, dropped %d)",
                          Double(framesSinceReport) / elapsed, _framesDisplayed, _framesDropped)
            lastReport = now
            framesSinceReport = 0
        }
        counterLock.unlock()

        if let line = line { log.info(line) }
    }

    private func recordDrop() {
        counterLock.lock()
        _framesDropped += 1
        counterLock.unlock()
        onFrameDropped?()
    }

    /// Clears the layer, e.g. on disconnect or before a resolution change.
    func flush() {
        displayLayer.flushAndRemoveImage()
        cursorLayer.isHidden = true
    }

    func resetCounters() {
        counterLock.lock()
        _framesDisplayed = 0
        _framesDropped = 0
        counterLock.unlock()
    }

    // MARK: - Cursor (main thread)

    func setVideoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        videoSize = size
        needsLayout = true
    }

    func updateCursor(_ update: ControlMessage.CursorUpdate) {
        if let png = update.imagePNG, let image = NSImage(data: png) {
            var rect = CGRect(origin: .zero, size: image.size)
            if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                cursorLayer.contents = cgImage
                cursorImageSize = CGSize(width: update.imageWidth ?? image.size.width,
                                         height: update.imageHeight ?? image.size.height)
                cursorHotspot = CGPoint(x: update.hotspotX ?? 0, y: update.hotspotY ?? 0)
            }
        }
        cursorPosition = update.visible ? CGPoint(x: update.x, y: update.y) : nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeCursor()
        CATransaction.commit()
    }

    /// The rectangle the aspect-fitted video occupies inside `bounds`.
    private var videoRect: CGRect {
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func placeCursor() {
        guard let position = cursorPosition, cursorLayer.contents != nil else {
            cursorLayer.isHidden = true
            return
        }
        let rect = videoRect
        // Cursor image is in points of the encoded display; scale it the same
        // way the video was scaled so it looks the size it does on the Host.
        let scale = rect.width / videoSize.width
        let size = CGSize(width: cursorImageSize.width * scale,
                          height: cursorImageSize.height * scale)
        let origin = CGPoint(x: rect.minX + position.x * rect.width - cursorHotspot.x * scale,
                             y: rect.minY + position.y * rect.height - cursorHotspot.y * scale)
        cursorLayer.frame = CGRect(origin: origin, size: size)
        cursorLayer.isHidden = false
    }
}
