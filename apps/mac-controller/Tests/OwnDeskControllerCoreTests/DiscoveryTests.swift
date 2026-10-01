import Testing
@testable import OwnDeskControllerCore

/// The "via" entry a Mac announces: only Tailscale addresses that parse are taken, and only three.
@Suite struct DiscoveryTests {
    @Test func onlyOverlayAddressesAreTaken() {
        typealias Host = HostDiscovery.DiscoveredHost
        #expect(Host.elsewhere(fromVia: "100.64.0.20:47500,[fd7a:115c:a1e0::20]:47500") == ["100.64.0.20:47500", "[fd7a:115c:a1e0::20]:47500"])
        // A stranger on the network cannot steer a device to the local network, the Internet, or a typo.
        #expect(Host.elsewhere(fromVia: "192.168.1.20:47500,8.8.8.8:47500,100.200.0.1:47500,100.64.0.1,nonsense") == [])
        #expect(Host.elsewhere(fromVia: nil) == [])
        #expect(Host.elsewhere(fromVia: String(repeating: "100.64.0.1:1,", count: 30)).isEmpty, "too long to be ours")
        #expect(Host.elsewhere(fromVia: "100.64.0.1:1,100.64.0.2:1,100.64.0.3:1,100.64.0.4:1").count == 3)
    }
}
