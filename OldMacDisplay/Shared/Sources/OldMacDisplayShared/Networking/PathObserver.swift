import Foundation
import Network

/// Watches the system's network path and reports which interface type is
/// actually carrying traffic.
///
/// Used by the Receiver to fill in `ClientCapabilities` (Ethernet vs Wi-Fi
/// decides the bitrate ceiling) and by both ends to notice a link change.
/// `NWPathMonitor` is macOS 10.14+, so it is safe on Catalina.
public final class PathObserver {
    public struct Snapshot: Equatable {
        public let isSatisfied: Bool
        public let activeType: NetworkType
        public let ethernetAvailable: Bool
        public let wifiAvailable: Bool

        public init(isSatisfied: Bool, activeType: NetworkType,
                    ethernetAvailable: Bool, wifiAvailable: Bool) {
            self.isSatisfied = isSatisfied
            self.activeType = activeType
            self.ethernetAvailable = ethernetAvailable
            self.wifiAvailable = wifiAvailable
        }

        public static let unknown = Snapshot(isSatisfied: false, activeType: .unknown,
                                             ethernetAvailable: false, wifiAvailable: false)
    }

    /// Fired on `queue` on every path change, and once on `start()`.
    public var onChange: ((Snapshot) -> Void)?

    public private(set) var snapshot: Snapshot = .unknown

    private let monitor = NWPathMonitor()
    private let queue: DispatchQueue
    private let log = Log(.network)

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit { monitor.cancel() }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let snapshot = PathObserver.snapshot(from: path)
            guard snapshot != self.snapshot else { return }
            self.snapshot = snapshot
            self.log.info("Network path: \(snapshot.activeType.rawValue), satisfied=\(snapshot.isSatisfied)")
            self.onChange?(snapshot)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

    static func snapshot(from path: NWPath) -> Snapshot {
        // Wired is checked first: when both are up macOS routes over Ethernet,
        // and that is also what we want to optimise the stream for.
        let activeType: NetworkType
        if path.usesInterfaceType(.wiredEthernet) {
            activeType = .ethernet
        } else if path.usesInterfaceType(.wifi) {
            activeType = .wifi
        } else if path.status == .satisfied {
            activeType = .other
        } else {
            activeType = .unknown
        }

        let interfaces = path.availableInterfaces
        let ethernetAvailable = interfaces.contains { $0.type == .wiredEthernet }
        let wifiAvailable = interfaces.contains { $0.type == .wifi }

        // A direct cable between two Macs carries no internet route, so the
        // default path reports `unsatisfied` and none of the `usesInterfaceType`
        // checks above match — the ideal setup would otherwise be reported as
        // `unknown`. Fall back to what is physically present.
        var resolvedType = activeType
        if resolvedType == .unknown {
            if ethernetAvailable {
                resolvedType = .ethernet
            } else if wifiAvailable {
                resolvedType = .wifi
            }
        }

        return Snapshot(
            isSatisfied: path.status == .satisfied,
            activeType: resolvedType,
            ethernetAvailable: ethernetAvailable,
            wifiAvailable: wifiAvailable)
    }
}
