import AppKit
import Network
import OwnDeskPeers
import Foundation
import OwnDeskProtocol
import Testing
@testable import OwnDeskControllerCore

@Suite struct VideoGeometryTests {
    @Test func letterboxedVideoMapsToTheContentArea() throws {
        let g = VideoGeometry(viewSize: CGSize(width: 1000, height: 500), videoSize: CGSize(width: 1920, height: 1080))
        let r = g.contentRect
        #expect(abs(r.height - 500) < 0.01)
        #expect(abs(r.width - 888.89) < 0.1)
        #expect(abs(r.minX - 55.56) < 0.1)
        let center = try #require(g.normalize(CGPoint(x: 500, y: 250)))
        #expect(abs(center.x - 0.5) < 0.001 && abs(center.y - 0.5) < 0.001)
        #expect(g.normalize(CGPoint(x: 10, y: 250)) == nil, "letterbox is not the screen")
        let corner = try #require(g.normalize(CGPoint(x: r.maxX, y: r.maxY)))
        #expect(corner.x == 1 && corner.y == 1)
    }

    @Test func pillarboxedAndDegenerateSizes() {
        let g = VideoGeometry(viewSize: CGSize(width: 500, height: 1000), videoSize: CGSize(width: 1000, height: 500))
        #expect(g.contentRect == CGRect(x: 0, y: 375, width: 500, height: 250))
        #expect(VideoGeometry(viewSize: .zero, videoSize: CGSize(width: 1, height: 1)).normalize(.zero) == nil)
    }
}

@Suite struct KeyMapTests {
    @Test func inversionOfTheSharedTable() {
        #expect(KeyMap.w3cCode(for: 0) == "KeyA")
        #expect(KeyMap.w3cCode(for: 36) == "Enter")
        #expect(KeyMap.w3cCode(for: 126) == "ArrowUp")
        #expect(KeyMap.w3cCode(for: 114) == "Insert", "Help and Insert share a code; Insert wins")
        #expect(KeyMap.w3cCode(for: 999) == nil)
        #expect(KeyMap.macOSToW3C.count == Set(KeyCodeTable.w3cToMacOS.values).count)
    }

    @Test func modifiersAndModifierKeys() {
        #expect(KeyMap.modifiers(from: [.command, .shift]) == [.shift, .meta])
        #expect(KeyMap.modifiers(from: []) == [])
        #expect(KeyMap.modifierFlag(forKeyCode: 56) == .shift)
        #expect(KeyMap.modifierFlag(forKeyCode: 55) == .command)
        #expect(KeyMap.modifierFlag(forKeyCode: 0) == nil)
    }
}

@Suite struct PathAndEndpointTests {
    @Test func pathClassification() {
        #expect(PathClassifier.classify(localType: "host", remoteType: "prflx", localAddress: "192.168.1.2", remoteAddress: "") == "Direct (LAN)")
        #expect(PathClassifier.classify(localType: "srflx", remoteType: "srflx", localAddress: "203.0.113.5", remoteAddress: "198.51.100.7") == "Direct (Internet)")
        #expect(PathClassifier.classify(localType: "relay", remoteType: "host", localAddress: "203.0.113.5", remoteAddress: "192.168.1.3") == "Relayed")
        #expect(PathClassifier.isPrivate("100.100.1.1") && !PathClassifier.isPrivate("100.200.1.1"))
        #expect(PathClassifier.classify(localType: "host", remoteType: "host", localAddress: "100.64.0.10", remoteAddress: "100.64.0.11") == "Direct (Tailscale)")
        #expect(PathClassifier.isOverlay("100.64.0.1") && PathClassifier.isOverlay("100.127.255.254"))
        #expect(PathClassifier.isOverlay("fd7a:115c:a1e0::a"), "Tailscale's IPv6 ULA prefix")
        #expect(PathClassifier.classify(localType: "host", remoteType: "host", localAddress: "fd7a:115c:a1e0::1", remoteAddress: "fd7a:115c:a1e0::2") == "Direct (Tailscale)")
        #expect(!PathClassifier.isOverlay("fd00::1"), "other unique-local IPv6 is not Tailscale")
        #expect(!PathClassifier.isOverlay("100.128.0.1") && !PathClassifier.isOverlay("100.63.0.1") && !PathClassifier.isOverlay("192.168.1.1"))
    }

    @Test func declaredPathTellsTheHostHowMuchBandwidthToAssume() {
        // Tailscale addresses are private but may be relayed, so they must not claim LAN bandwidth.
        #expect(SessionClient.path(forHost: "192.168.1.50") == .lan)
        #expect(SessionClient.path(forHost: "10.0.0.5") == .lan)
        #expect(SessionClient.path(forHost: "100.64.0.10") == .cloud)
        #expect(SessionClient.path(forHost: "fd7a:115c:a1e0::a") == .cloud)
        #expect(SessionClient.path(forHost: "203.0.113.5") == .cloud)
        #expect(SessionClient.path(forHost: nil) == .cloud)
    }

    @Test func endpointParsing() {
        #expect(Endpoints.url(for: "192.168.1.20:47500")?.absoluteString == "ws://192.168.1.20:47500/")
        #expect(Endpoints.url(for: "[fd7a:115c:a1e0::1]:47500")?.absoluteString == "ws://[fd7a:115c:a1e0::1]:47500/")
        #expect(Endpoints.url(for: "mac-mini.local:47500")?.host == "mac-mini.local")
        #expect(Endpoints.url(host: "fe80::1%en0", port: 5)?.absoluteString == "ws://[fe80::1%25en0]:5/")
        #expect(Endpoints.url(for: "192.168.1.20") == nil)
        #expect(Endpoints.url(for: "[fd7a::1]") == nil)
        #expect(Endpoints.url(for: ":47500") == nil)
        #expect(Endpoints.url(for: "192.168.1.20:99999") == nil)
    }

    @Test func firstReachablePicksTheAddressThatAnswers() async throws {
        // A listener on loopback stands in for the reachable address; a closed port and an
        // unroutable address stand in for a home LAN seen from elsewhere.
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = Box(UInt16(0))
        listener.stateUpdateHandler = { if case .ready = $0 { ready.update { $0 = listener.port?.rawValue ?? 0 } } }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: DispatchQueue(label: "owndesk.test.listener"))
        defer { listener.cancel() }
        try await E2E.waitUntil(timeoutMs: 5000, "listener ready") { ready.get() != 0 }

        let good = Endpoints.url(for: "127.0.0.1:\(ready.get())")!
        let dead = Endpoints.url(for: "192.0.2.1:47500")!   // TEST-NET-1, never routable
        let closed = Endpoints.url(for: "127.0.0.1:1")!

        #expect(await Endpoints.firstReachable([dead, closed, good], timeoutMs: 3000) == good)
        #expect(await Endpoints.firstReachable([good], timeoutMs: 3000) == good)
        #expect(await Endpoints.firstReachable([dead, closed], timeoutMs: 2000) == nil)
        #expect(await Endpoints.firstReachable([], timeoutMs: 1000) == nil)
    }

    @Test func resolvesHostPortEndpointsWithoutNetwork() async {
        let url = await Endpoints.resolve(.hostPort(host: "192.168.1.20", port: 47500))
        #expect(url?.absoluteString == "ws://192.168.1.20:47500/")
    }
}

@Suite struct ControllerPeerStoreTests {
    @Test func onlyPeersWeMayControlAppearAsHosts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("owndesk-ctl-\(UUID().uuidString)")
        let store = try PeerStore(directory: dir)
        let id = String(repeating: "ab", count: 32)
        try store.pair(deviceId: id, publicKey: String(repeating: "A", count: 87), name: "Mini", type: .mac,
                       mayControlUs: true, weMayControl: true, addresses: ["10.0.0.2:47500"], now: 1)
        store.touchConnected(id, at: 5, address: "10.0.0.3:47500")

        let reloaded = try PeerStore(directory: dir)
        #expect(reloaded.hosts.count == 1)
        #expect(reloaded.host(id)?.lastConnected == 5)
        #expect(reloaded.host(id)?.addresses == ["10.0.0.3:47500", "10.0.0.2:47500"])

        // Dropping it from our host list leaves the other direction intact.
        try reloaded.setWeMayControl(id, false)
        #expect(reloaded.hosts.isEmpty)
        #expect(reloaded.controllers.count == 1)
        #expect(reloaded.hostKey(id) == nil)
    }
}
