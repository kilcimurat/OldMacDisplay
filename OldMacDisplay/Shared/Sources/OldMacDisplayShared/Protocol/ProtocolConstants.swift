import Foundation

/// Static facts about the OldMacDisplay wire protocol.
public enum OMDProtocol {
    /// Bumped whenever the wire format or message set changes incompatibly.
    public static let version: UInt8 = 1

    /// Bonjour service type advertised by the Host and browsed by the Receiver.
    public static let bonjourServiceType = "_oldmacdisplay._tcp"

    /// Default TCP port. 0 would let the system pick, but a fixed port makes
    /// manual/direct-Ethernet fallback (typing an IP by hand) possible.
    public static let defaultPort: UInt16 = 51843

    /// Keys used in the Bonjour TXT record so the Receiver can render a useful
    /// list entry before it has connected to anything.
    public enum TXTKey {
        public static let protocolVersion = "pv"
        public static let deviceName = "name"
        public static let deviceModel = "model"
        public static let osVersion = "os"
    }

    /// Upper bound on a single frame payload. Guards the receive loop against a
    /// corrupt or hostile length field causing a huge allocation.
    public static let maxPayloadLength: UInt32 = 32 * 1024 * 1024
}

/// Logical channels multiplexed over the transport.
///
/// Phase 1 carries only `.control` and all channels share a single TCP
/// connection, but the channel byte is on the wire from day one so video/audio/
/// input can be split onto their own connections (or QUIC streams) later without
/// a protocol break.
public enum OMDChannel: UInt8, CaseIterable, Equatable {
    case control = 0
    case video   = 1
    case audio   = 2
    case input   = 3
}
