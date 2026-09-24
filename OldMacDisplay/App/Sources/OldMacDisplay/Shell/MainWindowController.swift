import AppKit
import OldMacDisplayShared

/// The single window: one tab to share this Mac's screen, one to show another's.
///
/// Both roles live in one app so there is a single thing to copy to the old Mac
/// and a single thing to launch. Which tab is useful depends on the machine,
/// and the app works that out for itself.
final class MainWindowController: NSWindowController {

    private let tabView = NSTabView()
    private let hostPane = HostPaneController()
    private let receiverPane: ReceiverPaneController
    private let log = Log(.app)

    init(profile: ReceiverHardwareProfile, options: LaunchOptions) {
        receiverPane = ReceiverPaneController(profile: profile, options: options)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "OldMacDisplay"
        // Below this the cards start clipping their contents.
        window.minSize = NSSize(width: 560, height: 540)
        window.center()
        window.setFrameAutosaveName("OldMacDisplayMainWindow")
        super.init(window: window)

        buildTabs()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildTabs() {
        let hostItem = NSTabViewItem(identifier: "host")
        hostItem.label = "Share This Mac"
        hostItem.viewController = hostPane

        let receiverItem = NSTabViewItem(identifier: "receiver")
        receiverItem.label = "Use As Display"
        receiverItem.viewController = receiverPane

        tabView.addTabViewItem(hostItem)
        tabView.addTabViewItem(receiverItem)

        // NSTabView loads a tab's view only when it is first shown, which would
        // mean discovery never starts until the user clicks Receiver, and the
        // host never advertises until they click Host. Both halves should be
        // live from launch, so force both views to load now.
        _ = hostPane.view
        _ = receiverPane.view

        // Open on the tab this machine can actually use. An old Mac cannot
        // host, so showing it a disabled Host tab first would be a poor
        // first impression.
        tabView.selectTabViewItem(
            HostPaneController.isSupportedOnThisMac ? hostItem : receiverItem)

        tabView.translatesAutoresizingMaskIntoConstraints = false
        guard let contentView = window?.contentView else { return }
        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        ])
    }

    func start() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        log.info("Main window ready (hosting \(HostPaneController.isSupportedOnThisMac ? "supported" : "unsupported") on this Mac)")
    }

    func prepareForTermination() {
        receiverPane.prepareForTermination()
    }
}
