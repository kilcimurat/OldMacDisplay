import AppKit
import CoreGraphics
import OldMacDisplayShared

/// Follows the pointer over the virtual display and reports it out of band.
///
/// The video no longer carries the cursor (see `DisplayCapturer`), so moving
/// the mouse over a still desktop no longer forces a re-encode. Instead the
/// position is sampled at the stream's frame rate and sent only when it
/// changed, and the cursor image is sent only when its shape changed.
final class CursorTracker {

    /// Delivered on `queue`.
    var onUpdate: ((ControlMessage.CursorUpdate) -> Void)?

    private let displayID: CGDirectDisplayID
    private let queue: DispatchQueue
    private let log = Log(.input)
    private var timer: DispatchSourceTimer?
    private var imageTimer: DispatchSourceTimer?

    private var lastPosition: CGPoint?
    private var lastVisible = false
    private var lastImagePNG: Data?
    /// Set when the image changed and must ride along with the next update.
    private var pendingImage: (png: Data, hotspot: CGPoint, size: CGSize)?

    init(displayID: CGDirectDisplayID, queue: DispatchQueue) {
        self.displayID = displayID
        self.queue = queue
    }

    deinit { stop() }

    func start(frameRate: Int) {
        stop()
        let interval = 1.0 / Double(max(frameRate, 1))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.samplePosition() }
        self.timer = timer
        timer.resume()

        // The shape changes far less often than the position, and reading it
        // needs AppKit on the main thread, so it is polled slowly and
        // separately.
        let imageTimer = DispatchSource.makeTimerSource(queue: .main)
        imageTimer.schedule(deadline: .now(), repeating: 0.1, leeway: .milliseconds(20))
        imageTimer.setEventHandler { [weak self] in self?.sampleImage() }
        self.imageTimer = imageTimer
        imageTimer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        imageTimer?.cancel()
        imageTimer = nil
    }

    // MARK: - Sampling

    private func samplePosition() {
        // CGEvent's location is in global display coordinates with a top-left
        // origin, the same space as `CGDisplayBounds`, so no flipping.
        guard let location = CGEvent(source: nil)?.location else { return }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let visible = bounds.contains(location)
        let position = CGPoint(x: (location.x - bounds.minX) / bounds.width,
                               y: (location.y - bounds.minY) / bounds.height)

        let moved = visible && position != lastPosition
        let visibilityChanged = visible != lastVisible
        guard moved || visibilityChanged || pendingImage != nil else { return }

        lastPosition = visible ? position : nil
        lastVisible = visible

        let image = pendingImage
        pendingImage = nil
        onUpdate?(ControlMessage.CursorUpdate(
            x: min(max(position.x, 0), 1),
            y: min(max(position.y, 0), 1),
            visible: visible,
            imagePNG: image?.png,
            hotspotX: image.map { Double($0.hotspot.x) },
            hotspotY: image.map { Double($0.hotspot.y) },
            imageWidth: image.map { Double($0.size.width) },
            imageHeight: image.map { Double($0.size.height) }))
    }

    /// Main thread: `NSCursor.currentSystem` is AppKit.
    private func sampleImage() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let hotspot = cursor.hotSpot
        let size = image.size
        queue.async { [weak self] in
            guard let self = self, png != self.lastImagePNG else { return }
            self.lastImagePNG = png
            self.pendingImage = (png, hotspot, size)
            self.log.debug("Cursor image changed (\(png.count) bytes, \(Int(size.width))x\(Int(size.height)))")
        }
    }
}
