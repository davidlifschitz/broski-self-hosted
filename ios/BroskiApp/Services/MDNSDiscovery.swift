import Foundation
import Network

/// Discovers Broski bridges via mDNS (_broski._tcp.local)
/// FIX: properly resolves host IP from NWBrowser endpoint using NWConnection
@MainActor
class MDNSDiscovery: ObservableObject {
    @Published var discovered: [DiscoveredBridge] = []
    private var browser: NWBrowser?
    private var resolvers: [NWConnection] = []

    struct DiscoveredBridge: Identifiable {
        let id = UUID()
        let name: String
        let host: String
        let port: UInt16
        var wsURL: String { "ws://\(host):\(port)" }
    }

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_broski._tcp", domain: "local."), using: params)
        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Cancel old resolvers
                self.resolvers.forEach { $0.cancel() }
                self.resolvers = []
                for result in results {
                    self.resolveEndpoint(result.endpoint, name: "\(result.endpoint)")
                }
            }
        }
        browser?.start(queue: .main)
    }

    /// Opens a transient NWConnection to force endpoint resolution to a real IP
    private func resolveEndpoint(_ endpoint: NWEndpoint, name: String) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        resolvers.append(conn)
        conn.stateUpdateHandler = { [weak self] state in
            if case .preparing = state { return }
            if case .ready = state {
                // Extract resolved host + port
                if let innerEp = conn.currentPath?.remoteEndpoint,
                   case let .hostPort(host, port) = innerEp {
                    let hostStr = "\(host)"
                        .replacingOccurrences(of: "%en0", with: "")
                        .replacingOccurrences(of: "%lo0", with: "")
                    let portInt = UInt16(port.rawValue)
                    let bridge = DiscoveredBridge(name: name, host: hostStr, port: 7337)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if !self.discovered.contains(where: { $0.wsURL == bridge.wsURL }) {
                            self.discovered.append(bridge)
                        }
                    }
                }
                conn.cancel()
            } else if case .failed = state {
                conn.cancel()
            }
        }
        conn.start(queue: .global())
    }

    func stop() {
        resolvers.forEach { $0.cancel() }
        resolvers = []
        browser?.cancel()
        browser = nil
    }
}
