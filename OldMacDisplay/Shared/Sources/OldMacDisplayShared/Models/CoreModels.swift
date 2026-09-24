import Foundation

/// How a machine is attached to the LAN. Drives bitrate and codec defaults.
public enum NetworkType: String, Codable, Equatable {
    case ethernet
    case wifi
    case other
    case unknown
}

/// Video codec selection.
public enum VideoCodec: String, Codable, Equatable {
    case h264
    case hevc
}

/// User-facing quality preset on the Host.
public enum QualityPreset: String, Codable, Equatable, CaseIterable {
    case performance
    case balanced
    case quality
}

/// A concrete display mode (in points, plus a scale factor).
public struct DisplayMode: Codable, Equatable, Hashable {
    public let width: Int
    public let height: Int
    public let refreshRate: Int
    public let scaleFactor: Double

    public init(width: Int, height: Int, refreshRate: Int, scaleFactor: Double = 1.0) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.scaleFactor = scaleFactor
    }
}

extension DisplayMode: CustomStringConvertible {
    public var description: String {
        let scale = scaleFactor > 1.0 ? " @\(String(format: "%.0f", scaleFactor))x" : ""
        return "\(width)x\(height) @ \(refreshRate)Hz\(scale)"
    }
}

/// Identity of a machine on either end of the link.
public struct DeviceInfo: Codable, Equatable {
    public let deviceID: String
    public let name: String
    public let model: String
    public let osVersion: String

    public init(deviceID: String, name: String, model: String, osVersion: String) {
        self.deviceID = deviceID
        self.name = name
        self.model = model
        self.osVersion = osVersion
    }
}

/// What the Receiver (iMac) can do. Sent to the Host right after `Hello` so the
/// Host can pick a virtual display mode, codec and bitrate without guessing.
public struct ClientCapabilities: Codable, Equatable {
    public let displayWidth: Int
    public let displayHeight: Int
    public let backingScaleFactor: Double
    public let preferredFPS: Int
    public let h264HardwareDecode: Bool
    public let hevcHardwareDecode: Bool
    public let ethernetAvailable: Bool
    public let wifiAvailable: Bool
    public let activeNetworkType: NetworkType
    public let cpuModel: String
    public let gpuModel: String
    public let memoryGB: Int

    public init(displayWidth: Int,
                displayHeight: Int,
                backingScaleFactor: Double,
                preferredFPS: Int,
                h264HardwareDecode: Bool,
                hevcHardwareDecode: Bool,
                ethernetAvailable: Bool,
                wifiAvailable: Bool,
                activeNetworkType: NetworkType,
                cpuModel: String,
                gpuModel: String,
                memoryGB: Int) {
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.backingScaleFactor = backingScaleFactor
        self.preferredFPS = preferredFPS
        self.h264HardwareDecode = h264HardwareDecode
        self.hevcHardwareDecode = hevcHardwareDecode
        self.ethernetAvailable = ethernetAvailable
        self.wifiAvailable = wifiAvailable
        self.activeNetworkType = activeNetworkType
        self.cpuModel = cpuModel
        self.gpuModel = gpuModel
        self.memoryGB = memoryGB
    }
}

/// What the Host can do. Sent in response to `ClientCapabilities`.
public struct ServerCapabilities: Codable, Equatable {
    public let supportedCodecs: [VideoCodec]
    public let h264HardwareEncode: Bool
    public let hevcHardwareEncode: Bool
    public let supportsVirtualDisplay: Bool
    public let availableModes: [DisplayMode]

    public init(supportedCodecs: [VideoCodec],
                h264HardwareEncode: Bool,
                hevcHardwareEncode: Bool,
                supportsVirtualDisplay: Bool,
                availableModes: [DisplayMode]) {
        self.supportedCodecs = supportedCodecs
        self.h264HardwareEncode = h264HardwareEncode
        self.hevcHardwareEncode = hevcHardwareEncode
        self.supportsVirtualDisplay = supportsVirtualDisplay
        self.availableModes = availableModes
    }
}

/// The negotiated session parameters the Host decided on.
public struct SessionConfiguration: Codable, Equatable {
    public let mode: DisplayMode
    public let codec: VideoCodec
    public let targetBitrateBPS: Int

    public init(mode: DisplayMode, codec: VideoCodec, targetBitrateBPS: Int) {
        self.mode = mode
        self.codec = codec
        self.targetBitrateBPS = targetBitrateBPS
    }
}
