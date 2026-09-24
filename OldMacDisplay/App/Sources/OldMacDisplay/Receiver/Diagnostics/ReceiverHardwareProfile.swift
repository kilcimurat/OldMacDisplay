import Foundation
import AppKit
import Metal
import VideoToolbox
import CoreGraphics
import OldMacDisplayShared

/// Everything the Host needs to know about this iMac to pick sensible stream
/// settings. Nothing here is hardcoded: the 21.5" and 27" 2013 iMacs differ in
/// panel size, and later machines differ in codec support.
struct ReceiverHardwareProfile {
    let cpuModel: String
    let gpuModel: String
    let memoryGB: Int
    let modelIdentifier: String
    let osVersion: String
    /// Pixel dimensions of the main display (points × backing scale).
    let displayResolution: CGSize
    let backingScaleFactor: CGFloat
    let refreshRate: Int
    let supportsH264HardwareDecode: Bool
    let supportsHEVCHardwareDecode: Bool

    private static let log = Log(.app)

    static func detect() -> ReceiverHardwareProfile {
        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 1.0
        let pointSize = screen?.frame.size ?? CGSize(width: 1920, height: 1080)
        let pixelSize = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)

        let profile = ReceiverHardwareProfile(
            cpuModel: SystemFacts.cpuModel,
            gpuModel: detectGPU(),
            memoryGB: SystemFacts.physicalMemoryGB,
            modelIdentifier: SystemFacts.modelIdentifier,
            osVersion: SystemFacts.osVersionString,
            displayResolution: pixelSize,
            backingScaleFactor: scale,
            refreshRate: detectRefreshRate(),
            supportsH264HardwareDecode: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
            // A 2013 iMac has no HEVC decode block. We probe rather than assume,
            // but expect false — and the negotiator then keeps us on H.264.
            supportsHEVCHardwareDecode: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))

        log.info("Receiver profile: \(profile.summary)")
        return profile
    }

    private static func detectGPU() -> String {
        // Metal is available on Catalina and every Mac that can run it; the
        // default device is the one the renderer will later use anyway.
        if let device = MTLCreateSystemDefaultDevice() {
            return device.name
        }
        log.notice("No Metal device; renderer will have to fall back")
        return "Unknown"
    }

    /// `NSScreen.maximumFramesPerSecond` is macOS 12+, so read the CoreGraphics
    /// display mode instead. Built-in panels frequently report 0 here, in which
    /// case 60 Hz is the right assumption for a 2013 iMac.
    private static func detectRefreshRate() -> Int {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return 60 }
        let rate = mode.refreshRate
        guard rate > 0 else { return 60 }
        return Int(rate.rounded())
    }

    var summary: String {
        "\(modelIdentifier) · \(cpuModel) · \(gpuModel) · \(memoryGB) GB · "
            + "\(Int(displayResolution.width))x\(Int(displayResolution.height))@\(refreshRate) "
            + "(scale \(backingScaleFactor)) · h264hw=\(supportsH264HardwareDecode) "
            + "hevchw=\(supportsHEVCHardwareDecode)"
    }

    /// Builds the message sent to the Host during the handshake.
    func capabilities(network: PathObserver.Snapshot) -> ClientCapabilities {
        ClientCapabilities(
            displayWidth: Int(displayResolution.width),
            displayHeight: Int(displayResolution.height),
            backingScaleFactor: Double(backingScaleFactor),
            // Never ask for more than the panel can actually show.
            preferredFPS: min(refreshRate, 60),
            h264HardwareDecode: supportsH264HardwareDecode,
            hevcHardwareDecode: supportsHEVCHardwareDecode,
            ethernetAvailable: network.ethernetAvailable,
            wifiAvailable: network.wifiAvailable,
            activeNetworkType: network.activeType,
            cpuModel: cpuModel,
            gpuModel: gpuModel,
            memoryGB: memoryGB)
    }

    var deviceInfo: DeviceInfo {
        DeviceInfo(deviceID: SystemFacts.hardwareUUID,
                   name: SystemFacts.computerName,
                   model: modelIdentifier,
                   osVersion: osVersion)
    }
}
