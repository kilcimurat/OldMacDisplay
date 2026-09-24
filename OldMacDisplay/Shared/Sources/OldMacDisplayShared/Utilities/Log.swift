import Foundation
import os

/// Unified logging facade for the whole project.
///
/// Note on `os.Logger`: `Logger` is macOS 11+ only, and the Receiver must run on
/// Catalina 10.15, so this wrapper is backed by the older `OSLog` + `os_log` API
/// (available since 10.12) which is the same unified-logging system underneath.
/// Everything still lands in Console.app under the `com.oldmacdisplay` subsystem
/// and can be filtered by category exactly as `Logger` output would be.
public struct Log {
    /// Logging categories used across the project.
    public enum Category: String {
        case virtualDisplay = "virtual-display"
        case capture
        case encoder
        case network
        case decoder
        case renderer
        case discovery
        case audio
        case input
        case app
    }

    public static let subsystem = "com.oldmacdisplay"

    private let osLog: OSLog
    private let category: Category

    public init(_ category: Category) {
        self.category = category
        self.osLog = OSLog(subsystem: Log.subsystem, category: category.rawValue)
    }

    public func debug(_ message: @autoclosure () -> String) {
        emit(message(), .debug)
    }

    public func info(_ message: @autoclosure () -> String) {
        emit(message(), .info)
    }

    public func notice(_ message: @autoclosure () -> String) {
        emit(message(), .default)
    }

    public func error(_ message: @autoclosure () -> String) {
        emit(message(), .error)
    }

    public func fault(_ message: @autoclosure () -> String) {
        emit(message(), .fault)
    }

    /// Logs a failure without swallowing it. Every `catch` in the project should
    /// route through here (or `error`) rather than discarding the error.
    public func failure(_ context: String, _ error: Error) {
        emit("\(context): \(error)", .error)
    }

    private func emit(_ message: String, _ type: OSLogType) {
        // The message is marked public on purpose: this is a local LAN developer
        // tool and redacted logs would make field debugging on the iMac painful.
        os_log("%{public}@", log: osLog, type: type, message)
    }
}
