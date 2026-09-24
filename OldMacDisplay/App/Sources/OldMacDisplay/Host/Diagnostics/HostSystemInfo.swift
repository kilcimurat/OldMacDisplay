import Foundation
import VideoToolbox
import OldMacDisplayShared

/// What this Mac is and what its media hardware can do.
///
/// Gathered once at launch; feeds both the Bonjour TXT record (so the Receiver
/// can show "M2 Max" before connecting) and the `ServerCapabilities` message.
struct HostSystemInfo {
    let device: DeviceInfo
    let h264HardwareEncode: Bool
    let hevcHardwareEncode: Bool

    private static let log = Log(.app)

    static func current() -> HostSystemInfo {
        let device = DeviceInfo(
            deviceID: SystemFacts.hardwareUUID,
            name: SystemFacts.computerName,
            model: SystemFacts.modelIdentifier,
            osVersion: SystemFacts.osVersionString)

        return HostSystemInfo(
            device: device,
            h264HardwareEncode: supportsHardwareEncode(kCMVideoCodecType_H264),
            hevcHardwareEncode: supportsHardwareEncode(kCMVideoCodecType_HEVC))
    }

    /// Asks VideoToolbox whether a hardware encoder exists for this codec.
    ///
    /// `VTCopySupportedPropertyDictionaryForEncoderSpecification` is the
    /// supported way to probe without actually creating a session. On Apple
    /// Silicon both H.264 and HEVC should report true; we probe rather than
    /// assume so the answer stays correct on other hardware.
    private static func supportsHardwareEncode(_ codec: CMVideoCodecType) -> Bool {
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        var encoderID: CFString?
        var properties: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: 1920, height: 1080,
            codecType: codec,
            encoderSpecification: spec as CFDictionary,
            encoderIDOut: &encoderID,
            supportedPropertiesOut: &properties)

        if status != noErr {
            log.notice("No hardware encoder for codec \(codec) (status \(status))")
            return false
        }
        return true
    }
}
