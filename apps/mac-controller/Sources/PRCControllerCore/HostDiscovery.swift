import Foundation
import Network

/// Bonjour browser for hosts on the current network (spec section 17).
public final class HostDiscovery: @unchecked Sendable {
    public struct DiscoveredHost: Sendable, Equatable, Identifiable {
        public var deviceId: String
        public var name: String
        public var endpoint: NWEndpoint
        public var id: String { deviceId }
    }

    private let queue = DispatchQueue(label: "prc.discovery")
    private var browser: NWBrowser?
    private let serviceType: String
    public var onUpdate: (@Sendable ([DiscoveredHost]) -> Void)?

    public init(serviceType: String) {
        self.serviceType = serviceType
    }

    public func start() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var hosts: [DiscoveredHost] = []
            for result in results {
                guard case .bonjour(let txt) = result.metadata,
                      let id = txt.dictionary["id"], id.count == 64,
                      txt.dictionary["proto"] == "1"
                else { continue }
                hosts.append(DiscoveredHost(deviceId: id, name: txt.dictionary["name"] ?? "Mac", endpoint: result.endpoint))
            }
            self?.onUpdate?(hosts.sorted { $0.name < $1.name })
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { Log.app.error("browser failed: \(error.localizedDescription, privacy: .public)") }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}
