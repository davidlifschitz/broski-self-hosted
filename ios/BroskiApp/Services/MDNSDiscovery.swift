import Foundation
import Network

@MainActor
class MDNSDiscovery: ObservableObject {
    @Published var discovered: [DiscoveredBridge] = []
    private var browser: NWBrowser?

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
            Task { @MainActor in
                self?.discovered = results.compactMap { result in
                    if case let .service(name, _, _, _) = result.endpoint {
                        return DiscoveredBridge(name: name, host: name, port: 7337)
                    }
                    return nil
                }
            }
        }
        browser?.start(queue: .main)
    }

    func stop() { browser?.cancel(); browser = nil }
}
