import AppKit
import OldMacDisplayShared

final class OldMacDisplayAppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?
    private let log = Log(.app)

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install(appName: "OldMacDisplay")

        let profile = ReceiverHardwareProfile.detect()
        let options = LaunchOptions.parse()
        log.info("OldMacDisplay launched on \(profile.summary)")

        let controller = MainWindowController(profile: profile, options: options)
        mainWindow = controller
        controller.start()

        NSApp.activate(ignoringOtherApps: true)

        if let seconds = options.quitAfter {
            log.info("Will quit automatically after \(seconds)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindow?.prepareForTermination()
    }
}
