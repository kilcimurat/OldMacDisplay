import Foundation
import Network
import CoreMedia
import OldMacDisplayShared

/// The Receiver's side of a session with one Host.
///
/// Owns discovery-independent connection logic: connect, handshake, heartbeat,
/// and automatic reconnection within a grace period so a briefly unplugged
/// Ethernet cable does not end the session.
final class ReceiverClient {
    struct Status: Equatable {
        var state: ConnectionState = .idle
        var hostName: String?
        var hostDevice: DeviceInfo?
        var serverCapabilities: ServerCapabilities?
        var negotiated: SessionConfiguration?
        var latencyMilliseconds: Double?
        var networkType: NetworkType = .unknown
        var lastError: String?
        var video: ControlMessage.VideoConfiguration?
        var streaming = false
        var measuredFPS: Double = 0
        var measuredBitrateBPS: Int = 0
    }

    /// How long to keep retrying before declaring the session dead.
    var reconnectGracePeriod: TimeInterval = 30

    var onStatusChange: ((Status) -> Void)?
    /// Decoded-and-ready sample buffers, delivered on `callbackQueue`.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Supplies renderer counters for the stats report sent back to the Host.
    /// Set by the UI, which owns the display layer.
    var displayStatsProvider: (() -> (displayed: Int, dropped: Int))?

    private(set) var status = Status() {
        didSet {
            guard status != oldValue else { return }
            let snapshot = status
            callbackQueue.async { [weak self] in self?.onStatusChange?(snapshot) }
        }
    }

    private let profile: ReceiverHardwareProfile
    private let queue = DispatchQueue(label: "com.oldmacdisplay.receiver.network")
    private let callbackQueue: DispatchQueue
    private let pathObserver: PathObserver
    private let log = Log(.network)

    private var transport: NWMessageChannel?
    private var heartbeat: Heartbeat?
    private var stateMachine = ConnectionStateMachine()
    private var target: NWEndpoint?
    private var reconnectDeadline: Date?
    /// How long a connection may stay un-ready before it is treated as failed.
    private let connectTimeout: TimeInterval = 6
    private var connectWatchdog: DispatchSourceTimer?
    private var reconnectTimer: DispatchSourceTimer?
    private var userInitiatedDisconnect = false

    private let assembler = SampleBufferAssembler()
    private var lastKeyframeRequest: Double = 0
    private var videoWindowStart = MonotonicClock.now()
    private var videoWindowFrames = 0
    private var videoWindowBytes = 0

    init(profile: ReceiverHardwareProfile, callbackQueue: DispatchQueue = .main) {
        self.profile = profile
        self.callbackQueue = callbackQueue
        self.pathObserver = PathObserver(queue: queue)

        pathObserver.onChange = { [weak self] snapshot in
            guard let self = self else { return }
            // Only meaningful while a session exists: idle, the default path is
            // whatever this Mac happens to route the internet over, which says
            // nothing about how the Host would be reached.
            let link = self.transport?.currentInterfaceType ?? .unknown
            self.callbackQueue.async {
                self.status.networkType = link == .unknown ? .unknown : snapshot.activeType
            }
        }
        pathObserver.start()
    }

    // MARK: - Public API

    func connect(to host: DiscoveredHost) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.userInitiatedDisconnect = false
            self.target = host.endpoint
            self.reconnectDeadline = nil
            self.callbackQueue.async { self.status.hostName = host.serviceName }
            self.advance(.connectRequested)
            self.openTransport()
        }
    }

    /// `completion` runs once the goodbye frame has been handed to the
    /// transport, so a caller shutting the app down can wait for the flush.
    func disconnect(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.userInitiatedDisconnect = true
            let reason = "Disconnected by user"

            let finish: () -> Void = {
                self.advance(.disconnectRequested(reason: reason))
                self.teardown()
                completion?()
            }

            if let transport = self.transport {
                do {
                    try transport.sendControl(.disconnect(.init(reason: reason))) { _ in
                        finish()
                    }
                } catch {
                    self.log.failure("Encoding disconnect", error)
                    finish()
                }
            } else {
                finish()
            }

            self.clearSessionState()
        }
    }

    /// Clears everything that describes a live session.
    ///
    /// Must run on every path that ends one — user disconnect, host disconnect,
    /// protocol error, grace period expiry. Leaving `streaming`/`video` set was
    /// what kept the stream window open as a black rectangle after a
    /// disconnect: the UI re-opened it from stale state the moment it closed.
    private func clearSessionState() {
        callbackQueue.async { [weak self] in
            guard let self = self else { return }
            self.status.streaming = false
            self.status.video = nil
            self.status.hostDevice = nil
            self.status.negotiated = nil
            self.status.latencyMilliseconds = nil
            self.status.measuredFPS = 0
            self.status.measuredBitrateBPS = 0
            self.status.networkType = .unknown
        }
    }

    // MARK: - Transport lifecycle

    private func openTransport() {
        guard let target = target else { return }
        teardownTransport()

        let channel = NWMessageChannel(endpoint: target, queue: queue)
        channel.onStateChange = { [weak self] state in self?.handleTransport(state) }
        channel.onFrame = { [weak self] frame in self?.handle(frame) }
        channel.onError = { [weak self] error in
            self?.log.failure("Client transport", error)
        }
        transport = channel

        let heartbeat = Heartbeat(queue: queue) { [weak self] message in
            self?.sendControl(message)
        }
        heartbeat.onSample = { [weak self] tracker in
            guard let self = self else { return }
            self.callbackQueue.async { self.status.latencyMilliseconds = tracker.smoothedMilliseconds }
        }
        self.heartbeat = heartbeat

        armConnectWatchdog()
        channel.start()
    }

    /// `NWConnection` can sit in `.preparing` indefinitely when it is pinned to
    /// an interface that cannot reach the Host, emitting neither `waiting` nor
    /// `failed`. Without this the UI would show "Connecting" forever.
    private func armConnectWatchdog() {
        connectWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + connectTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.connectWatchdog = nil
            self.log.error("Connection did not become ready within \(Int(self.connectTimeout))s")
            self.status.lastError = "Connection timed out"

            self.beginReconnect()
        }
        connectWatchdog = timer
        timer.resume()
    }

    private func handleTransport(_ state: TransportState) {
        switch state {
        case .ready:
            connectWatchdog?.cancel()
            connectWatchdog = nil
            let link = transport?.currentInterfaceType ?? .unknown
            log.info("Connected over \(link.rawValue)")
            callbackQueue.async { [weak self] in self?.status.networkType = link }
            advance(.transportReady)
            reconnectDeadline = nil
            callbackQueue.async { [weak self] in self?.status.lastError = nil }
            sendHandshake()
            heartbeat?.start()

        case .failed(let reason):
            log.error("Transport failed: \(reason)")
            callbackQueue.async { [weak self] in self?.status.lastError = reason }
            beginReconnect()

        case .waiting(let reason):
            // NWConnection will sit here forever once the Host's listener has
            // gone away, so drive the retry ourselves.
            log.notice("Transport waiting (\(reason)); retrying")
            callbackQueue.async { [weak self] in self?.status.lastError = reason }
            beginReconnect()

        case .cancelled:
            if !userInitiatedDisconnect { beginReconnect() }

        case .setup, .preparing:
            break
        }
    }

    private func sendHandshake() {
        sendControl(.hello(.init(device: profile.deviceInfo)))

        // Prefer the interface this connection is genuinely using over the
        // system's default-path guess. On a direct Ethernet cable there is no
        // internet route, so the default path reports `unknown` and the Host
        // would cap the stream as if this were a poor wireless link — exactly
        // backwards for the best connection available.
        var snapshot = pathObserver.snapshot
        let actual = transport?.currentInterfaceType ?? .unknown
        if actual != .unknown, actual != snapshot.activeType {
            log.info("Link type from the live connection: \(actual.rawValue) (default path said \(snapshot.activeType.rawValue))")
            snapshot = PathObserver.Snapshot(
                isSatisfied: true,
                activeType: actual,
                ethernetAvailable: snapshot.ethernetAvailable || actual == .ethernet,
                wifiAvailable: snapshot.wifiAvailable || actual == .wifi)
        }
        callbackQueue.async { [weak self] in self?.status.networkType = snapshot.activeType }
        sendControl(.clientCapabilities(profile.capabilities(network: snapshot)))
    }

    // MARK: - Reconnection

    private func beginReconnect() {
        guard !userInitiatedDisconnect, target != nil else { return }

        // Drop the dead connection now: left alive it keeps firing `waiting`
        // callbacks, which would re-enter this method on every one of them.
        teardownTransport()
        advance(.transportFailed(reason: status.lastError ?? "Connection lost"))

        // Start the clock on the first failure only, so the grace period covers
        // the whole outage rather than restarting with every retry.
        if reconnectDeadline == nil {
            reconnectDeadline = Date().addingTimeInterval(reconnectGracePeriod)
            log.info("Entering reconnect grace period of \(Int(reconnectGracePeriod))s")
        }

        guard let deadline = reconnectDeadline, Date() < deadline else {
            log.error("Reconnect grace period expired; giving up")
            advance(.gracePeriodExpired)
            teardown()
            clearSessionState()
            return
        }

        // Backoff capped at 2s: on a LAN the peer usually returns quickly and a
        // long backoff would just add dead time.
        let attempt = stateMachine.reconnectAttempts


        let delay = min(pow(1.5, Double(attempt - 1)) * 0.25, 2.0)
        log.info("Reconnect attempt \(attempt) in \(String(format: "%.2f", delay))s")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.openTransport() }
        reconnectTimer?.cancel()
        reconnectTimer = timer
        timer.resume()
    }

    private func teardownTransport() {
        connectWatchdog?.cancel()
        connectWatchdog = nil
        // The next connection restarts the encoder, so the old parameter sets
        // no longer describe the incoming bitstream.
        assembler.reset()
        heartbeat?.stop()
        heartbeat = nil
        transport?.onStateChange = nil
        transport?.onFrame = nil
        transport?.stop()
        transport = nil
    }

    private func teardown() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
        reconnectDeadline = nil
        teardownTransport()
    }

    // MARK: - Messages

    private func handle(_ frame: OMDFrame) {
        if frame.channel == .video {
            handleVideo(frame)
            return
        }
        guard frame.channel == .control else { return }

        let message: ControlMessage
        do {
            message = try ControlCodec.decode(frame.payload)
        } catch {
            log.failure("Decoding control message", error)
            return
        }

        if heartbeat?.handle(message) == true { return }

        switch message {
        case .hello(let hello):
            log.info("Host is \(hello.device.name) (\(hello.device.model), macOS \(hello.device.osVersion))")
            callbackQueue.async { [weak self] in
                self?.status.hostDevice = hello.device
                self?.status.hostName = hello.device.name
            }

        case .serverCapabilities(let capabilities):
            log.info("Host codecs: \(capabilities.supportedCodecs.map { $0.rawValue }.joined(separator: ", "))")
            callbackQueue.async { [weak self] in self?.status.serverCapabilities = capabilities }
            // Capabilities exchanged in both directions: handshake is done.
            advance(.handshakeCompleted)

        case .videoConfiguration(let configuration):
            log.info("Incoming stream: \(configuration.codec.rawValue) \(configuration.encodedWidth)x\(configuration.encodedHeight) @\(configuration.frameRate)")
            assembler.configure(codec: configuration.codec)
            callbackQueue.async { [weak self] in self?.status.video = configuration }

        case .streamStart:
            log.info("Stream started")
            resetVideoStats()
            callbackQueue.async { [weak self] in self?.status.streaming = true }

        case .streamStop:
            log.info("Stream stopped")
            assembler.reset()
            callbackQueue.async { [weak self] in
                self?.status.streaming = false
                self?.status.measuredFPS = 0
            }

        case .displayConfiguration(let config):
            log.info("Host negotiated \(config.mode) \(config.codec.rawValue)")
            callbackQueue.async { [weak self] in self?.status.negotiated = config }

        case .disconnect(let payload):
            log.info("Host disconnected: \(payload.reason)")
            userInitiatedDisconnect = true
            advance(.disconnectRequested(reason: payload.reason))
            teardown()
            clearSessionState()

        case .error(let payload):
            log.error("Host error \(payload.code): \(payload.message)")
            callbackQueue.async { [weak self] in self?.status.lastError = payload.message }
            if payload.code == "E_BUSY" || payload.code == "E_VERSION" {
                // Not transient: retrying would just be rejected again.
                userInitiatedDisconnect = true
                advance(.disconnectRequested(reason: payload.message))
                teardown()
                clearSessionState()
            }

        default:
            log.debug("Ignoring \(message.kind.rawValue) in phase 1")
        }
    }

    // MARK: - Video

    private func handleVideo(_ frame: OMDFrame) {
        let packet: VideoPacket
        do {
            packet = try VideoPacket.decode(frame.payload)
        } catch {
            log.failure("Decoding video packet", error)
            return
        }

        switch packet.kind {
        case .parameterSets:
            do {
                let sets = try ParameterSets.decode(packet.payload)
                try assembler.setParameterSets(
                    sets, nalUnitHeaderLength: Int(packet.nalUnitHeaderLength))
            } catch {
                log.failure("Applying parameter sets", error)
            }

        case .accessUnit:
            guard assembler.isReady else {
                // Joined mid-GOP. Ask for an IDR; parameter sets ride along
                // with it.
                requestKeyframeThrottled()
                return
            }
            do {
                let sampleBuffer = try assembler.makeSampleBuffer(from: packet)
                recordVideoStats(byteCount: packet.payload.count)
                callbackQueue.async { [weak self] in self?.onSampleBuffer?(sampleBuffer) }
            } catch {
                log.failure("Building sample buffer", error)
                requestKeyframeThrottled()
            }
        }
    }

    /// At most one keyframe request per second: the Host cannot answer faster,
    /// and a flood would waste the control channel during a bad patch.
    private func requestKeyframeThrottled() {
        let now = MonotonicClock.now()
        guard now - lastKeyframeRequest > 1.0 else { return }
        lastKeyframeRequest = now
        log.info("Requesting a keyframe")
        sendControl(.requestKeyframe)
    }

    private func recordVideoStats(byteCount: Int) {
        videoWindowFrames += 1
        videoWindowBytes += byteCount

        let now = MonotonicClock.now()
        let elapsed = now - videoWindowStart
        guard elapsed >= 1.0 else { return }

        let fps = Double(videoWindowFrames) / elapsed
        let bitrate = Int(Double(videoWindowBytes * 8) / elapsed)
        callbackQueue.async { [weak self] in
            self?.status.measuredFPS = fps
            self?.status.measuredBitrateBPS = bitrate
        }
        reportStatsToHost(fps: fps, bitrate: bitrate)
        videoWindowStart = now
        videoWindowFrames = 0
        videoWindowBytes = 0
    }

    /// Tells the Host how the stream is actually arriving here.
    ///
    /// This is the only truthful backpressure signal in the system. The Host
    /// cannot infer congestion from its own sends: `NWConnection` reports a
    /// frame as processed once the kernel accepts it into the socket buffer,
    /// which happens immediately even when the link is stalled. Only the
    /// Receiver knows how many frames actually made it to the screen.
    private func reportStatsToHost(fps: Double, bitrate: Int) {
        let display = displayStatsProvider?() ?? (displayed: 0, dropped: 0)
        let total = display.displayed + display.dropped
        let dropRatio = total > 0 ? Double(display.dropped) / Double(total) : 0

        sendControl(.networkStats(.init(
            fps: fps,
            bitrateBPS: bitrate,
            droppedFrameRatio: dropRatio,
            decodeMillis: 0,   // not separable with AVSampleBufferDisplayLayer
            renderMillis: 0)))
    }

    private func resetVideoStats() {
        videoWindowStart = MonotonicClock.now()
        videoWindowFrames = 0
        videoWindowBytes = 0
    }

    private func sendControl(_ message: ControlMessage) {
        guard let transport = transport else { return }
        do {
            try transport.sendControl(message)
        } catch {
            log.failure("Encoding \(message.kind.rawValue)", error)
        }
    }

    private func advance(_ event: ConnectionEvent) {
        guard stateMachine.handle(event) else { return }
        let state = stateMachine.state
        callbackQueue.async { [weak self] in self?.status.state = state }
    }
}
