import AppKit
import CoreMedia
import OldMacDisplayShared

/// The window the stream is shown in — the one that should feel like a monitor.
///
/// Separate from the connection window so entering full screen does not take the
/// controls with it, and so closing the stream does not end the session.
final class VideoWindowController: NSWindowController, NSWindowDelegate {

    /// Called when the user closes the stream window or leaves the session.
    var onClose: (() -> Void)?
    /// The renderer discarded a frame; forwarded from the video view on the
    /// enqueueing thread.
    var onFrameDropped: (() -> Void)? {
        get { videoView.onFrameDropped }
        set { videoView.onFrameDropped = newValue }
    }

    private let videoView = VideoDisplayView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    private let log = Log(.renderer)

    /// Cursor auto-hide. Input is not forwarded yet, so a pointer sitting on top
    /// of the stream is pure distraction.
    private var cursorHideTimer: Timer?
    private var cursorHidden = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "OldMacDisplay"
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        super.init(window: window)

        window.delegate = self
        window.contentView = videoView
        videoView.autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Presentation

    func show(enterFullScreen: Bool) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if enterFullScreen { window?.toggleFullScreen(nil) }
        startCursorTimer()
    }

    /// Sizes the window to the stream so the image is shown 1:1 when windowed.
    func adopt(configuration: ControlMessage.VideoConfiguration) {
        let size = NSSize(width: configuration.encodedWidth, height: configuration.encodedHeight)
        videoView.setVideoSize(size)
        guard let window = window, !isFullScreen else { return }
        // Never open larger than the panel it is being shown on.
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size
            ?? NSSize(width: 1280, height: 720)
        let scale = min(1.0, min(visible.width / size.width, visible.height / size.height))
        window.setContentSize(NSSize(width: size.width * scale, height: size.height * scale))
        window.center()
    }

    /// Any thread.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        videoView.enqueue(sampleBuffer)
    }

    /// Main thread.
    func updateCursor(_ update: ControlMessage.CursorUpdate) {
        videoView.updateCursor(update)
    }

    func clear() {
        videoView.flush()
    }

    var isFullScreen: Bool {
        window?.styleMask.contains(.fullScreen) ?? false
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    /// Renderer counters, reported back to the Host as the real measure of how
    /// much of the stream is reaching the screen. Any thread.
    var displayCounters: (displayed: Int, dropped: Int) {
        (displayed: videoView.framesDisplayed, dropped: videoView.framesDropped)
    }

    var statsSummary: String {
        "displayed \(videoView.framesDisplayed), dropped \(videoView.framesDropped)"
    }

    // MARK: - Cursor

    private func startCursorTimer() {
        cursorHideTimer?.invalidate()
        cursorHideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] _ in
            self?.hideCursorIfIdle()
        }
    }

    private func hideCursorIfIdle() {
        guard let window = window, window.isKeyWindow, isFullScreen, !cursorHidden else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
        cursorHidden = true
    }

    override func mouseMoved(with event: NSEvent) {
        cursorHidden = false
        super.mouseMoved(with: event)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        cursorHideTimer?.invalidate()
        cursorHideTimer = nil
        onClose?()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        log.info("Entered full screen")
        window?.acceptsMouseMovedEvents = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        log.info("Left full screen")
        cursorHidden = false
    }
}
