import Foundation
@testable import OldMacDisplayShared

/// In-memory `MessageTransport` pair used by tests.
///
/// Lets the handshake, ping/pong and reconnect logic be exercised end-to-end
/// with no sockets and no second Mac. `deliverSynchronously` keeps tests
/// deterministic; set `dropOutbound` to simulate a dead link.
final class LoopbackTransport: MessageTransport {
    var onStateChange: ((TransportState) -> Void)?
    var onFrame: ((OMDFrame) -> Void)?
    var onError: ((Error) -> Void)?

    weak var peer: LoopbackTransport?
    var dropOutbound = false
    var currentInterfaceType: NetworkType = .ethernet
    private(set) var sentFrames: [OMDFrame] = []

    func start() {
        onStateChange?(.preparing)
        onStateChange?(.ready)
    }

    func send(_ frame: OMDFrame, completion: ((Error?) -> Void)?) {
        sentFrames.append(frame)
        defer { completion?(nil) }
        guard !dropOutbound else { return }
        // Round-trip through the real wire format so framing bugs surface here
        // rather than only against a physical iMac.
        guard let encoded = try? WireFormat.encode(frame) else { return }
        peer?.ingest(encoded)
    }

    func stop() {
        onStateChange?(.cancelled)
    }

    private let parser = FrameParser()

    private func ingest(_ data: Data) {
        do {
            for frame in try parser.append(data) {
                onFrame?(frame)
            }
        } catch {
            onError?(error)
        }
    }

    static func pair() -> (LoopbackTransport, LoopbackTransport) {
        let a = LoopbackTransport()
        let b = LoopbackTransport()
        a.peer = b
        b.peer = a
        return (a, b)
    }
}
