import Foundation
import Network
import CoreGraphics
import OldMacDisplayShared

/// Ties Bonjour advertising to session management.
///
/// Phase 1 accepts a single Receiver at a time: a second inbound connection is
/// rejected immediately with an explicit error rather than being silently
/// dropped, so the Receiver can explain what happened.
final class HostServer {
    struct Status: Equatable {
        var advertising = false
        var port: UInt16 = OMDProtocol.defaultPort
        var connectionState: ConnectionState = .idle
        var peer: HostSession.Peer?
        var negotiated: SessionConfiguration?
        var latencyMilliseconds: Double?
        var lastError: String?
        var streaming = false
        var measuredFPS: Double = 0
        var measuredBitrateBPS: Int = 0
        var encodeMillis: Double = 0
        /// Frames dropped on the send side because the network stalled.
        var networkDroppedFrames = 0
        /// What the Receiver reports it is actually displaying. This, not the
        /// host-side figure, is what the user is looking at.
        var receiverFPS: Double?
        var receiverDropRatio: Double?
        /// Set once macOS is actually extending onto our virtual display.
        var virtualDisplayID: CGDirectDisplayID?
    }

    var onStatusChange: ((Status) -> Void)?

    private(set) var status = Status() {
        didSet {
            guard status != oldValue else { return }
            let snapshot = status
            callbackQueue.async { [weak self] in self?.onStatusChange?(snapshot) }
        }
    }

    let systemInfo: HostSystemInfo

    private let queue = DispatchQueue(label: "com.oldmacdisplay.host.network")
    private let callbackQueue: DispatchQueue
    private let advertiser: BonjourAdvertiser
    private var session: HostSession?
    private var streamController: AnyObject?
    private let virtualDisplayProvider: VirtualDisplayProvider = CGVirtualDisplayProvider()
    private var preferences: HostPreferences
    private let log = Log(.network)

    init(systemInfo: HostSystemInfo = .current(),
         preferences: HostPreferences = .default,
         callbackQueue: DispatchQueue = .main) {
        self.systemInfo = systemInfo
        self.preferences = preferences
        self.callbackQueue = callbackQueue
        self.advertiser = BonjourAdvertiser(queue: queue)
    }

    func start() {
        advertiser.onStateChange = { [weak self] state in
            guard let self else { return }
            self.callbackQueue.async {
                switch state {
                case .advertising(let port):
                    self.status.advertising = true
                    self.status.port = port
                    self.status.lastError = nil
                case .stopped:
                    self.status.advertising = false
                case .failed(let reason):
                    self.status.advertising = false
                    self.status.lastError = reason
                }
            }
        }
        advertiser.onNewConnection = { [weak self] connection in
            self?.accept(connection)
        }
        advertiser.start(device: systemInfo.device)
    }

    func stop() {
        stopStreaming()
        session?.disconnect(reason: "Host stopped")
        session = nil
        advertiser.stop()
        callbackQueue.async { [weak self] in
            self?.status.advertising = false
            self?.status.connectionState = .idle
        }
    }

    func disconnectCurrentSession() {
        session?.disconnect(reason: "Disconnected by host")
    }

    func updatePreferences(_ preferences: HostPreferences) {
        self.preferences = preferences
        session?.updatePreferences(preferences)
    }

    // MARK: - Sessions

    private func accept(_ connection: NWConnection) {
        guard session == nil else {
            log.notice("Rejecting second Receiver from \(connection.endpoint); one session at a time")
            reject(connection, reason: "Host is already connected to another display")
            return
        }

        let session = HostSession(connection: connection,
                                  systemInfo: systemInfo,
                                  preferences: preferences,
                                  queue: queue,
                                  callbackQueue: callbackQueue)
        self.session = session

        session.onStateChange = { [weak self] state in
            self?.status.connectionState = state
        }
        session.onPeerChange = { [weak self] peer in
            self?.status.peer = peer
        }
        session.onNegotiated = { [weak self] config in
            guard let self else { return }
            self.status.negotiated = config
            self.startStreaming(config, on: session)
        }
        session.onReceiverStats = { [weak self] stats in
            self?.status.receiverFPS = stats.fps
            self?.status.receiverDropRatio = stats.droppedFrameRatio
        }
        session.onDroppedFrame = { [weak self] total in
            self?.status.networkDroppedFrames = total
        }
        session.onKeyframeRequested = { [weak self] in
            guard #available(macOS 13.0, *),
                  let controller = self?.streamController as? StreamController else { return }
            controller.requestKeyframe()
        }
        session.onLatency = { [weak self] tracker in
            self?.status.latencyMilliseconds = tracker.smoothedMilliseconds
        }
        session.onEnded = { [weak self] ended in
            guard let self, self.session === ended else { return }
            self.stopStreaming()
            self.session = nil
            self.status.peer = nil
            self.status.negotiated = nil
            self.status.latencyMilliseconds = nil
        }
        session.start()
    }

    // MARK: - Streaming

    private func startStreaming(_ configuration: SessionConfiguration, on session: HostSession) {
        guard #available(macOS 13.0, *) else {
            let message = "Screen capture requires macOS 13 or later on the host."
            log.error(message)
            status.lastError = message
            return
        }

        // Create the extra desktop first, then capture only that. Without it
        // we would be mirroring the main display, which is not the point.
        //
        // Off the main thread: macOS registers the display through the main run
        // loop, so waiting for it there would deadlock.
        virtualDisplayProvider.createDisplay(
            configuration: VirtualDisplayConfiguration(mode: configuration.mode)
        ) { [weak self, weak session] result in
            guard let self = self, let session = session else { return }
            switch result {
            case .failure(let error):
                self.log.failure("Creating virtual display", error)
                self.status.lastError = error.localizedDescription

            case .success(let display):
                self.status.virtualDisplayID = display.displayID

                // macOS may have restored a remembered mode, so stream what is
                // actually on screen rather than what we asked for.
                let actual = SessionConfiguration(
                    mode: DisplayMode(width: display.width,
                                      height: display.height,
                                      refreshRate: configuration.mode.refreshRate),
                    codec: configuration.codec,
                    targetBitrateBPS: configuration.targetBitrateBPS)

                self.beginCapture(actual, displayID: display.displayID, on: session)
            }
        }
    }

    private func beginCapture(_ configuration: SessionConfiguration,
                              displayID: CGDirectDisplayID,
                              on session: HostSession) {
        guard #available(macOS 13.0, *) else { return }

        let controller = (streamController as? StreamController) ?? StreamController()
        streamController = controller

        controller.onConfiguration = { [weak session] videoConfiguration in
            session?.startVideoStream(videoConfiguration)
        }
        controller.onPacket = { [weak session] packet in
            session?.sendVideo(packet)
        }
        controller.onError = { [weak self] message in
            self?.callbackQueue.async {
                self?.status.lastError = message
                self?.status.streaming = false
            }
        }
        controller.onStats = { [weak self] stats in
            self?.callbackQueue.async {
                self?.status.streaming = true
                self?.status.measuredFPS = stats.measuredFPS
                self?.status.measuredBitrateBPS = stats.measuredBitrateBPS
                self?.status.encodeMillis = stats.averageEncodeMillis
            }
        }

        controller.start(configuration: configuration, displayID: displayID)
    }

    private func stopStreaming() {
        if #available(macOS 13.0, *), let controller = streamController as? StreamController {
            controller.stop()
        }
        streamController = nil
        virtualDisplayProvider.destroyDisplay()
        status.virtualDisplayID = nil
        status.streaming = false
        status.measuredFPS = 0
        status.measuredBitrateBPS = 0
        status.encodeMillis = 0
        status.networkDroppedFrames = 0
        status.receiverFPS = nil
        status.receiverDropRatio = nil
    }

    /// Sends a protocol-level explanation before hanging up, so the Receiver can
    /// show a real reason instead of "connection closed".
    private func reject(_ connection: NWConnection, reason: String) {
        let channel = NWMessageChannel(connection: connection, queue: queue)
        channel.onStateChange = { state in
            guard case .ready = state else { return }
            try? channel.sendControl(.error(.init(code: "E_BUSY", message: reason)))
            // Give the frame a moment to flush before cancelling.
            self.queue.asyncAfter(deadline: .now() + 0.2) { channel.stop() }
        }
        channel.start()
    }
}
