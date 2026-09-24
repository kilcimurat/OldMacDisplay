import AppKit

// Explicit bootstrap rather than @main: the SwiftUI App lifecycle is macOS 11+
// and this app must launch on Catalina.
let application = NSApplication.shared
let delegate = OldMacDisplayAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()

