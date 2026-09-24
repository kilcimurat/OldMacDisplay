import AppKit
import CoreMedia
import OldMacDisplayShared

/// The "Use As Display" tab: find a Mac to show, connect, open the stream window.
///
/// The stream itself lives in a separate borderless window (`VideoWindowController`)
/// so it can go full screen without dragging these controls along.
final class ReceiverPaneController: NSViewController {

    private let profile: ReceiverHardwareProfile
    private let options: LaunchOptions
    private let browser: BonjourBrowser
    private let client: ReceiverClient
    private let log = Log(.app)

    /// Everything discovery has found, before the link filter is applied.
    private var discovered: [DiscoveredHost] = []
    /// What the table shows: `discovered` narrowed to the selected link.
    private var hosts: [DiscoveredHost] = []
    private var link: LinkFilter = ReceiverPaneController.savedLink {
        didSet {
            guard link != oldValue else { return }
            ReceiverPaneController.savedLink = link
            applyLinkFilter()
        }
    }
    private var videoWindow: VideoWindowController?
    private var hasAutoConnected = false
    /// Set while we close the stream window ourselves, so the window's own
    /// close notification does not bounce back in as a second disconnect.
    private var isClosingVideoWindow = false

    private let tableView = NSTableView()
    private let statusDot = PaneStyle.StatusDot()
    private let linkControl = NSSegmentedControl(
        labels: LinkFilter.allCases.map { $0.title },
        trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Searching for Macs…")
    private let detailLabel = NSTextField(labelWithString: "")
    private let latencyLabel = NSTextField(labelWithString: "Latency: —")
    private let hardwareLabel = NSTextField(labelWithString: "")
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let fullScreenButton = NSButton(title: "Enter Full Screen", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)

    init(profile: ReceiverHardwareProfile, options: LaunchOptions) {
        self.profile = profile
        self.options = options
        self.browser = BonjourBrowser(
            queue: DispatchQueue(label: "com.oldmacdisplay.receiver.discovery"))
        self.client = ReceiverClient(profile: profile)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 470))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        wireUp()
        browser.start()
        connectDirectlyIfRequested()
    }

    // MARK: - UI

    private func buildUI() {
        linkControl.selectedSegment = link.rawValue
        linkControl.target = self
        linkControl.action = #selector(linkChanged)
        linkControl.controlSize = .small

        let header = PaneStyle.row([
            PaneStyle.title("Available Macs"), PaneStyle.spacer(), linkControl
        ])

        tableView.addTableColumn(NSTableColumn(identifier: .init("host")))
        tableView.headerView = nil
        tableView.rowHeight = 46
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        if #available(macOS 11.0, *) { tableView.style = .inset }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let listCard = PaneStyle.card(scrollView)
        listCard.translatesAutoresizingMaskIntoConstraints = false

        // MARK: Status card

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let statusRow = PaneStyle.row([statusDot, statusLabel], spacing: 8)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byWordWrapping

        latencyLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        latencyLabel.textColor = .secondaryLabelColor

        let statusColumn = PaneStyle.column([statusRow, detailLabel, latencyLabel], spacing: 5)
        let statusCard = PaneStyle.card(statusColumn)
        statusCard.translatesAutoresizingMaskIntoConstraints = false

        // MARK: Buttons

        connectButton.target = self
        connectButton.action = #selector(connectTapped)
        connectButton.keyEquivalent = "\r"
        connectButton.isEnabled = false
        if #available(macOS 11.0, *) { connectButton.controlSize = .large }

        fullScreenButton.target = self
        fullScreenButton.action = #selector(fullScreenTapped)
        fullScreenButton.isEnabled = false

        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectTapped)
        disconnectButton.isEnabled = false

        // Connect sits at the trailing edge, where macOS puts the action a
        // dialog expects you to take.
        let buttons = PaneStyle.row([
            fullScreenButton, disconnectButton, PaneStyle.spacer(), connectButton
        ])

        hardwareLabel.font = .systemFont(ofSize: 10)
        hardwareLabel.textColor = .tertiaryLabelColor
        hardwareLabel.maximumNumberOfLines = 3
        hardwareLabel.lineBreakMode = .byWordWrapping
        hardwareLabel.stringValue = profile.summary

        let stack = NSStackView(views: [
            header, listCard, statusCard, buttons, hardwareLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PaneStyle.Metrics.sectionSpacing
        stack.setCustomSpacing(8, after: header)
        stack.setCustomSpacing(10, after: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: PaneStyle.Metrics.paneInset,
                                        left: PaneStyle.Metrics.paneInset,
                                        bottom: PaneStyle.Metrics.paneInset,
                                        right: PaneStyle.Metrics.paneInset)
        view.addSubview(stack)

        // Everything spans the pane width so the cards line up as one column.
        let full = { (child: NSView) in
            child.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                         constant: -PaneStyle.Metrics.paneInset * 2)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            listCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 176),
            full(header), full(listCard), full(statusCard),
            full(buttons), full(detailLabel), full(hardwareLabel)
        ])

        render(client.status)
    }

    private func wireUp() {
        browser.onResultsChange = { [weak self] hosts in
            guard let self = self else { return }
            self.discovered = hosts
            self.applyLinkFilter()
            self.autoConnectIfRequested()
        }
        browser.onError = { [weak self] message in
            self?.statusLabel.stringValue = "Discovery error: \(message)"
        }
        client.onStatusChange = { [weak self] status in self?.render(status) }
        client.onCursor = { [weak self] update in
            self?.videoWindow?.updateCursor(update)
        }
    }

    /// Points the client's frame path at a window, or at nothing.
    ///
    /// The sink runs on the network queue and must not touch this
    /// controller's state, so it captures the window controller itself rather
    /// than reaching through `self.videoWindow`, which is a main-thread
    /// property.
    private func routeVideo(to window: VideoWindowController?) {
        guard let window = window else {
            client.setVideoSink(nil)
            client.setDisplayStatsProvider(nil)
            return
        }
        window.onFrameDropped = { [weak client] in client?.requestKeyframe() }
        client.setVideoSink { [weak window] sampleBuffer in
            window?.enqueue(sampleBuffer)
        }
        client.setDisplayStatsProvider { [weak window] in
            window?.displayCounters ?? (displayed: 0, dropped: 0)
        }
    }

    // MARK: - Link filter

    private static let savedLinkKey = "receiver.linkFilter"

    private static var savedLink: LinkFilter {
        get {
            let stored = UserDefaults.standard.object(forKey: savedLinkKey) as? Int
            return stored.flatMap(LinkFilter.init(rawValue:)) ?? .ethernet
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: savedLinkKey) }
    }

    @objc private func linkChanged() {
        guard let chosen = LinkFilter(rawValue: linkControl.selectedSegment) else { return }
        link = chosen
    }

    /// Narrows the discovered Hosts to the selected link and refreshes the table,
    /// keeping the current selection on the same Mac where it still qualifies.
    private func applyLinkFilter() {
        let previous = hosts.indices.contains(tableView.selectedRow)
            ? hosts[tableView.selectedRow] : nil

        hosts = discovered.filter { $0.isReachable(over: link) }
        tableView.reloadData()

        let restored = previous.flatMap { host in
            hosts.firstIndex { $0.serviceName == host.serviceName }
        }
        if let row = restored ?? (hosts.isEmpty ? nil : 0) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateButtons()
        render(client.status)
    }

    // MARK: - Actions

    private func connectDirectlyIfRequested() {
        guard let address = options.directAddress else { return }
        guard let host = DiscoveredHost(address: address) else {
            log.error("Could not parse --connect address '\(address)'")
            statusLabel.stringValue = "Invalid address: \(address)"
            return
        }
        log.info("Connecting directly to \(address)")
        hasAutoConnected = true
        client.connect(to: host)
    }

    private func autoConnectIfRequested() {
        guard options.autoConnect, !hasAutoConnected else { return }
        guard let index = hosts.firstIndex(where: { options.matches($0) && $0.isCompatible })
        else { return }
        hasAutoConnected = true
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        log.info("Auto-connecting to \(hosts[index].serviceName) (listed under \(link.title))")
        client.connect(to: hosts[index])
    }

    @objc private func connectTapped() {
        let row = tableView.selectedRow
        guard hosts.indices.contains(row) else { return }
        log.info("Connecting to \(hosts[row].serviceName) (listed under \(link.title))")
        client.connect(to: hosts[row])
    }

    @objc private func disconnectTapped() {
        client.disconnect()
        closeVideoWindow()
    }

    @objc private func fullScreenTapped() {
        videoWindow?.toggleFullScreen()
    }

    func prepareForTermination() {
        browser.stop()
        closeVideoWindow()
        // Block briefly so the goodbye frame reaches the host before exit.
        let flushed = DispatchSemaphore(value: 0)
        client.disconnect { flushed.signal() }
        _ = flushed.wait(timeout: .now() + 0.5)
    }

    // MARK: - Stream window

    private func presentVideoWindow(for configuration: ControlMessage.VideoConfiguration) {
        if videoWindow == nil {
            let controller = VideoWindowController()
            controller.onClose = { [weak self] in
                guard let self = self else { return }
                self.videoWindow = nil
                self.routeVideo(to: nil)
                self.updateButtons()
                // Closing the stream window is how someone sitting at the old
                // Mac says "I'm done" — there is no other visible sign of the
                // session there, so leaving it connected would strand it.
                guard !self.isClosingVideoWindow else { return }
                self.log.info("Stream window closed; disconnecting")
                self.client.disconnect()
            }
            videoWindow = controller
            routeVideo(to: controller)
            controller.show(enterFullScreen: false)
            log.info("Opened stream window")
        }
        videoWindow?.adopt(configuration: configuration)
        updateButtons()
    }

    private func closeVideoWindow() {
        guard let window = videoWindow else { return }
        isClosingVideoWindow = true
        routeVideo(to: nil)
        window.clear()
        window.close()
        videoWindow = nil
        isClosingVideoWindow = false
        updateButtons()
    }

    // MARK: - Rendering

    private func render(_ status: ReceiverClient.Status) {
        // The stream window follows the session, not the frame flow. During a
        // brief reconnect it stays up showing the last frame; it only goes away
        // when the session is genuinely over.
        switch status.state {
        case .idle, .disconnected:
            closeVideoWindow()
        case .connecting, .handshaking, .connected, .reconnecting:
            if status.streaming, let video = status.video {
                presentVideoWindow(for: video)
            }
        }

        switch status.state {
        case .idle:
            statusLabel.stringValue = hosts.isEmpty
                ? link.emptyMessage : "Select a Mac and click Connect"
            statusDot.apply(.idle)
        case .connecting:
            statusLabel.stringValue = "Connecting to \(status.hostName ?? "host")…"
            statusDot.apply(.working)
        case .handshaking:
            statusLabel.stringValue = "Negotiating…"
            statusDot.apply(.working)
        case .connected:
            statusLabel.stringValue = "Connected to \(status.hostName ?? "host")"
            statusDot.apply(.live)
        case .reconnecting(let attempt):
            statusLabel.stringValue = "Reconnecting (attempt \(attempt))…"
            statusDot.apply(.working)
        case .disconnected(let reason):
            statusLabel.stringValue = "Disconnected — \(reason)"
            statusDot.apply(.failed)
        }

        var details: [String] = []
        if let config = status.negotiated {
            details.append("\(config.mode)")
            details.append(config.codec.rawValue.uppercased())
        }
        if status.streaming, status.measuredFPS > 0 {
            details.append(String(format: "%.0f fps", status.measuredFPS))
            details.append(String(format: "%.1f Mbps",
                                  Double(status.measuredBitrateBPS) / 1_000_000))
        }
        if status.networkType != .unknown {
            var link = status.networkType == .ethernet
                ? "over Ethernet" : "over \(status.networkType.rawValue.capitalized)"
            if status.videoOnSeparateConnection { link += " (2 connections)" }
            details.append(link)
        }
        if let error = status.lastError { details.append(error) }
        PaneStyle.setText(detailLabel, details.joined(separator: " · "))

        var latency = status.latencyMilliseconds
            .map { String(format: "Latency: %.1f ms round trip", $0) } ?? "Latency: —"
        if let endToEnd = status.endToEndMilliseconds {
            latency += String(format: " · %.0f ms capture → screen", endToEnd)
        }
        latencyLabel.stringValue = latency

        updateButtons()
    }

    private func updateButtons() {
        let hasSelection = hosts.indices.contains(tableView.selectedRow)
        let active: Bool
        switch client.status.state {
        case .connecting, .handshaking, .connected, .reconnecting: active = true
        case .idle, .disconnected: active = false
        }
        connectButton.isEnabled = hasSelection && !active
        disconnectButton.isEnabled = active
        fullScreenButton.isEnabled = videoWindow != nil
    }
}

// MARK: - Table

extension ReceiverPaneController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { hosts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard hosts.indices.contains(row) else { return nil }
        let host = hosts[row]

        // `NSImage.computerName` is an old AppKit stock icon, so it is present
        // on Catalina too — SF Symbols are macOS 11+.
        let icon = NSImageView()
        icon.image = NSImage(named: NSImage.computerName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let name = NSTextField(labelWithString: host.serviceName)
        name.font = .systemFont(ofSize: 13, weight: .medium)

        let subtitle = NSTextField(labelWithString: host.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = host.isCompatible ? .secondaryLabelColor : .systemRed
        subtitle.lineBreakMode = .byTruncatingTail

        let text = PaneStyle.column([name, subtitle], spacing: 1)

        let stack = PaneStyle.row([icon, text], spacing: 10)
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}
