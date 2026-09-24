import Foundation
import OldMacDisplayShared

/// Command-line options, used for automated and two-machine integration checks.
///
///   --auto-connect [name]   connect to the first discovered Host, optionally
///                           requiring its name to contain `name`
///   --connect <host[:port]> skip Bonjour and connect straight to an address.
///                           Needed for a direct Ethernet cable, where there may
///                           be no mDNS, and used by the loopback diagnostics.
///   --quit-after <seconds>  exit automatically; keeps a scripted run bounded
///
/// With no arguments the Receiver behaves as a normal interactive app.
struct LaunchOptions {
    var autoConnect = false
    var autoConnectNameFilter: String?
    var quitAfter: TimeInterval?
    var directAddress: String?

    static func parse(_ arguments: [String] = CommandLine.arguments) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--auto-connect":
                options.autoConnect = true
                // An optional value may follow, but must not swallow the next flag.
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    options.autoConnectNameFilter = arguments[index + 1]
                    index += 1
                }
            case "--connect":
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    options.directAddress = arguments[index + 1]
                    index += 1
                } else {
                    Log(.app).error("--connect needs a host or host:port")
                }

            case "--quit-after":
                if index + 1 < arguments.count, let seconds = Double(arguments[index + 1]) {
                    options.quitAfter = seconds
                    index += 1
                } else {
                    Log(.app).error("--quit-after needs a number of seconds")
                }
            default:
                // Ignore unknown arguments: macOS passes its own (-NSDocumentRevisions…).
                break
            }
            index += 1
        }
        return options
    }

    func matches(_ host: DiscoveredHost) -> Bool {
        guard let filter = autoConnectNameFilter else { return true }
        return host.serviceName.range(of: filter, options: .caseInsensitive) != nil
    }
}
