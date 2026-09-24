import Foundation
import CoreGraphics
import OMDPrivateDisplay
import OldMacDisplayShared

/// `VirtualDisplayProvider` backed by private CoreGraphics API.
///
/// All private-API contact is inside the `OMDPrivateDisplay` Objective-C
/// target; this type only adds policy — stable monitor identity, waiting for
/// the display to appear, and teardown ordering.
final class CGVirtualDisplayProvider: VirtualDisplayProvider {

    private(set) var currentDisplay: VirtualDisplay?
    private var handle: OMDVirtualDisplayHandle?
    private let log = Log(.virtualDisplay)

    var isSupported: Bool { OMDVirtualDisplayBridge.isAvailable() }
    var availabilityReport: String { OMDVirtualDisplayBridge.availabilityReport() }

    /// macOS remembers per-monitor settings keyed on
    /// (vendorID, productID, serialNumber) and **restores the last mode it saw
    /// for that identity**, ignoring the mode we just asked for.
    ///
    /// Measured: after creating 1920x1080 once, a later request for 2560x1440
    /// under the same identity came back as 1920x1080.
    ///
    /// So the serial number is derived from the mode. Each resolution gets its
    /// own stable identity: the requested mode is honoured, and the arrangement
    /// for that mode is still remembered across launches.
    private enum Identity {
        static let vendorID: UInt32 = 0x4F4D_4400   // "OMD\0"
        static let productID: UInt32 = 0x0001

        static func serialNumber(for configuration: VirtualDisplayConfiguration) -> UInt32 {
            var hash: UInt32 = 2_166_136_261 // FNV-1a
            for value in [UInt32(configuration.width),
                          UInt32(configuration.height),
                          UInt32(configuration.refreshRate),
                          configuration.hiDPI ? 1 : 0] {
                hash = (hash ^ value) &* 16_777_619
            }
            // Zero is treated as "no serial"; keep it out of range.
            return hash == 0 ? 1 : hash
        }
    }

    /// Creating and releasing the display each trigger a display
    /// reconfiguration inside WindowServer, and the calls themselves block for
    /// a noticeable fraction of a second. They run here so the UI never
    /// freezes at connect or disconnect. Serial, so a destroy always lands
    /// before the create that follows it.
    private let workQueue = DispatchQueue(label: "com.oldmacdisplay.host.virtual-display",
                                          qos: .userInitiated)

    deinit { destroyDisplay() }

    func createDisplay(configuration: VirtualDisplayConfiguration,
                       completion: @escaping (Result<VirtualDisplay, Error>) -> Void) {
        let finish: (Result<VirtualDisplay, Error>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }

        guard isSupported else {
            log.error(availabilityReport)
            finish(.failure(VirtualDisplayError.unsupported(availabilityReport)))
            return
        }

        // One at a time; a second display would just be a second thing to keep
        // in sync with the single Receiver.
        destroyDisplay()

        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.log.info("Creating virtual display \(configuration.width)x\(configuration.height) @\(configuration.refreshRate)Hz (hiDPI \(configuration.hiDPI))")

            // The bridge's NSError** surfaces in Swift as `throws`.
            let handle: OMDVirtualDisplayHandle
            do {
                handle = try OMDVirtualDisplayBridge.createDisplay(
                    withName: configuration.name,
                    width: UInt32(configuration.width),
                    height: UInt32(configuration.height),
                    refreshRate: Double(configuration.refreshRate),
                    hiDPI: configuration.hiDPI,
                    vendorID: Identity.vendorID,
                    productID: Identity.productID,
                    serialNumber: Identity.serialNumber(for: configuration))
            } catch {
                self.log.failure("Virtual display creation", error)
                finish(.failure(VirtualDisplayError.creationFailed(error.localizedDescription)))
                return
            }

            // Creation is asynchronous inside macOS: the object exists before
            // the display is listed, and registration runs on the main run
            // loop, so this poll must never happen on the main thread.
            guard Self.waitForDisplay(handle.displayID, timeout: 3.0) else {
                self.log.error("Display \(handle.displayID) never appeared in the active list")
                handle.invalidate()
                finish(.failure(VirtualDisplayError.didNotAppear))
                return
            }
            DispatchQueue.main.async {
                self.finishCreation(handle: handle, configuration: configuration, finish: finish)
            }
        }
    }

    private func finishCreation(handle: OMDVirtualDisplayHandle,
                                configuration: VirtualDisplayConfiguration,
                                finish: @escaping (Result<VirtualDisplay, Error>) -> Void) {
        self.handle = handle

        // Trust macOS over our request: if it restored a remembered mode, the
        // encoder must be configured for the size actually on screen.
        let actualWidth = Int(CGDisplayPixelsWide(handle.displayID))
        let actualHeight = Int(CGDisplayPixelsHigh(handle.displayID))
        if actualWidth != configuration.width || actualHeight != configuration.height {
            log.notice("Requested \(configuration.width)x\(configuration.height) but macOS created \(actualWidth)x\(actualHeight); using the actual size")
        }

        let display = VirtualDisplay(displayID: handle.displayID,
                                     name: configuration.name,
                                     width: actualWidth,
                                     height: actualHeight,
                                     refreshRate: configuration.refreshRate)
        self.currentDisplay = display

        log.info("Virtual display active: id \(display.displayID), \(display.width)x\(display.height)")
        finish(.success(display))
    }

    func destroyDisplay() {
        guard let handle = handle else { return }
        let id = handle.displayID
        self.handle = nil
        self.currentDisplay = nil
        // Releasing the object is what removes the display, and that call
        // blocks while WindowServer reconfigures. Off the main thread.
        // Removal is asynchronous beyond that too; macOS can keep listing it
        // briefly. Nothing downstream depends on it being gone.
        workQueue.async { [log] in
            log.info("Destroying virtual display \(id)")
            handle.invalidate()
        }
    }

    /// Polls `CGGetActiveDisplayList` until the new display shows up.
    ///
    /// Must be called off the main thread: macOS registers the display via the
    /// main run loop, so blocking that thread here stops the very event being
    /// waited for and the display never appears.
    private static func waitForDisplay(_ displayID: CGDirectDisplayID,
                                       timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if activeDisplayIDs().contains(displayID) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
