import Foundation
import Network

/// `MessageTransport` implemented on Network.framework.
///
/// Available on macOS 10.15, so the same implementation serves the Catalina
/// Receiver and the modern Host. Deliberately callback-based (no async/await) to
/// keep the Receiver binary free of back-deployed concurrency runtime.
public final class NWMessageChannel: MessageTransport {
    public var onStateChange: ((TransportState) -> Void)?
    public var onFrame: ((OMDFrame) -> Void)?
    public var onError: ((Error) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let parser = FrameParser()
    private let log = Log(.network)
    private var stopped = false

    /// Wraps an already-created connection (server side, from `NWListener`).
    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Creates an outbound connection (client side).
    public convenience init(endpoint: NWEndpoint, queue: DispatchQueue) {
        self.init(connection: NWConnection(to: endpoint, using: NWMessageChannel.parameters()),
                  queue: queue)
    }

    /// Low-latency TCP parameters shared by both ends.
    ///
    /// Deliberately places no interface constraint on the connection. Two kinds
    /// were tried, to keep a VPN from stealing a LAN session, and both stalled
    /// it instead: `requiredInterface` pinned to the NIC a Bonjour service was
    /// discovered on, and `prohibitedInterfaceTypes` excluding the links the
    /// user had not picked. In each case `NWConnection` sat in `.preparing`
    /// indefinitely — emitting neither `waiting` nor `failed` — because a
    /// resolved Bonjour endpoint carries addresses for every one of the peer's
    /// interfaces, and a constraint that rules out the route to the address
    /// being tried leaves nothing to fall back to. Measured directly against a
    /// running Host: unconstrained connects (and picks Ethernet on its own,
    /// since routing already prefers it); Wi-Fi-only never connects at all.
    ///
    /// So the link choice in the Use As Display pane filters which Hosts are
    /// listed, and routing decides the path. Keeping a VPN off the session is
    /// unsolved; see docs/RECEIVER_COMPATIBILITY.md.
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = TCPTuning.noDelay
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = TCPTuning.keepaliveIdleSeconds
        tcp.keepaliveCount = TCPTuning.keepaliveCount
        tcp.keepaliveInterval = TCPTuning.keepaliveIntervalSeconds
        tcp.connectionTimeout = TCPTuning.connectionTimeoutSeconds

        let params = NWParameters(tls: nil, tcp: tcp)
        // Ask the scheduler to treat this as interactive traffic.
        params.serviceClass = .responsiveData

        return params
    }

    public var currentInterfaceType: NetworkType {
        guard let interface = connection.currentPath?.availableInterfaces.first else {
            return .unknown
        }
        switch interface.type {
        case .wiredEthernet: return .ethernet
        case .wifi:          return .wifi
        case .cellular, .loopback, .other: return .other
        @unknown default:    return .other
        }
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .setup:
                self.onStateChange?(.setup)
            case .preparing:
                self.onStateChange?(.preparing)
            case .waiting(let error):
                self.log.notice("Transport waiting on \(self.connection.endpoint): \(error)")
                self.onStateChange?(.waiting(error.localizedDescription))
            case .ready:
                self.log.info("Transport ready to \(self.connection.endpoint)")
                self.onStateChange?(.ready)
                self.receiveLoop()
            case .failed(let error):
                self.log.error("Transport failed: \(error)")
                self.onStateChange?(.failed(error.localizedDescription))
            case .cancelled:
                self.onStateChange?(.cancelled)
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ frame: OMDFrame, completion: ((Error?) -> Void)?) {
        let data: Data
        do {
            data = try WireFormat.encode(frame)
        } catch {
            log.failure("Encoding outbound frame", error)
            onError?(error)
            completion?(error)
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.log.failure("Sending frame", error)
                self?.onError?(error)
            }
            completion?(error)
        })
    }

    public func stop() {
        stopped = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    // MARK: - Receive

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self = self, !self.stopped else { return }

            if let data = data, !data.isEmpty {
                do {
                    for frame in try self.parser.append(data) {
                        self.onFrame?(frame)
                    }
                } catch {
                    // A malformed stream is unrecoverable: there is no way to
                    // resynchronise safely, so surface it and tear down.
                    self.log.failure("Parsing inbound stream", error)
                    self.onError?(error)
                    self.onStateChange?(.failed("Protocol error: \(error)"))
                    self.stop()
                    return
                }
            }

            if let error = error {
                self.log.failure("Receiving", error)
                self.onError?(error)
                self.onStateChange?(.failed(error.localizedDescription))
                return
            }

            if isComplete {
                self.log.info("Peer closed the connection")
                self.onStateChange?(.cancelled)
                return
            }

            self.receiveLoop()
        }
    }
}
