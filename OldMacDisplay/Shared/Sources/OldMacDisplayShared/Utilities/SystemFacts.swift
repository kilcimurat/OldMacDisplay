import Foundation
import SystemConfiguration

/// Thin sysctl/host-name helpers used by both the Host and Receiver hardware
/// profilers. Everything here is available on Catalina.
public enum SystemFacts {

    /// Reads a string-valued sysctl, e.g. `hw.model`, `machdep.cpu.brand_string`.
    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Reads an integer-valued sysctl. Handles both 32- and 64-bit values.
    public static func integer(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case MemoryLayout<Int32>.size:
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int64(value)
        case MemoryLayout<Int64>.size:
            var value: Int64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return value
        default:
            return nil
        }
    }

    /// Hardware model identifier, e.g. `iMac14,2` or `Mac14,6`.
    public static var modelIdentifier: String {
        string("hw.model") ?? "Unknown"
    }

    /// CPU brand string. On Apple Silicon `machdep.cpu.brand_string` returns
    /// e.g. "Apple M2 Max"; on the Intel iMac it returns the full Intel name.
    public static var cpuModel: String {
        string("machdep.cpu.brand_string") ?? modelIdentifier
    }

    public static var physicalMemoryGB: Int {
        Int((ProcessInfo.processInfo.physicalMemory + (1 << 29)) >> 30)
    }

    public static var osVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The user-visible machine name, e.g. "Murat's MacBook Pro".
    ///
    /// `ProcessInfo.hostName` would return the mDNS name with a `.local` suffix
    /// and with spaces replaced by hyphens, which reads badly in the UI.
    public static var computerName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        return ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
    }

    /// A stable per-machine identifier for the trusted-device list added later.
    /// Derived from the hardware UUID so it survives reinstalls.
    public static var hardwareUUID: String {
        string("kern.uuid") ?? modelIdentifier
    }
}
