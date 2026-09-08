import Foundation
import Network
import PRCAgentCore
import PRCIdentity
import PRCPeers
import PRCProtocol
import Testing
import WebRTC
@testable import PRCControllerCore

final class Box<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return v }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

final class CountingRenderer: NSObject, RTCVideoRenderer {
    let frames = Box(0)
    let size = Box(CGSize.zero)
    func setSize(_ size: CGSize) { self.size.update { $0 = size } }
    func renderFrame(_ frame: RTCVideoFrame?) { frames.update { $0 += 1 } }
}

enum E2E {
    struct TestError: Error { let message: String }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prc-ctl-e2e-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func waitUntil(timeoutMs: Int = 10000, _ label: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw TestError(message: "timeout: \(label)")
    }

    /// A real in-process agent with the synthetic screen and input disabled, plus a recorder of its events
    /// that auto-approves pairing requests.
    static func startAgent(media: Bool) async throws -> (Agent, Box<[AgentEvent]>) {
        var config = AgentConfig(hostName: "Test Mini", port: 0, advertiseBonjour: false, dataDirectory: tempDir(), mediaEnabled: media, inputEnabled: false)
        config.syntheticScreen = true
        let agent = try Agent(config: config, identity: SoftwareIdentity())
        let events = Box<[AgentEvent]>([])
        let coordinator = agent.coordinator
        let stream = agent.events
        Task {
            for await e in stream {
                events.update { $0.append(e) }
                if case .pairingRequest = e { await coordinator.resolvePairing(approved: true) }
            }
        }
        try agent.start()
        try await waitUntil("agent port") { agent.port != 0 }
        return (agent, events)
    }
}

@Suite(.serialized) struct ControllerEndToEndTests {
    @Test func pairConnectStreamPingAndDisconnect() async throws {
        let (agent, agentEvents) = try await E2E.startAgent(media: true)
        let address = "127.0.0.1:\(agent.port)"

        // Pairing through the real signaling server, with the host approving.
        let qr = await agent.coordinator.openPairing()
        let identity = SoftwareIdentity()
        let pairing = PairingClient(identity: identity, deviceName: "Test MacBook")
        let outcome = try await pairing.pair(qr: qr, preferredAddress: address)
        #expect(outcome.host.deviceId == agent.identity.deviceId)
        #expect(outcome.host.publicKey == agent.identity.publicKeyB64)
        #expect(outcome.host.name == "Test Mini")
        #expect(outcome.address == address)
        #expect(agent.peers.controller(identity.deviceId)?.name == "Test MacBook")

        // Session.
        let config = ControllerConfig(deviceName: "Test MacBook", dataDirectory: E2E.tempDir(), pingIntervalMs: 300)
        let session = SessionClient(.init(identity: identity, host: outcome.host, config: config))
        let states = Box<[SessionClient.State]>([])
        let rtts = Box<[Double]>([])
        let displays = Box<[DisplayInfo]>([])
        let stream = session.events
        Task {
            for await e in stream {
                switch e {
                case .state(let s): states.update { $0.append(s) }
                case .rtt(let r): rtts.update { $0.append(r) }
                case .display(let d): displays.update { $0.append(d) }
                default: break
                }
            }
        }
        let renderer = CountingRenderer()
        await session.attach(renderer: renderer)
        await session.connect(url: Endpoints.url(for: address)!)

        try await E2E.waitUntil(timeoutMs: 20000, "connected") {
            states.get().contains { if case .connected = $0 { return true } else { return false } }
        }
        let order = states.get()
        #expect(order.first == .connecting)
        #expect(order.contains(.authenticating) && order.contains(.negotiating))
        if case .connected(let path)? = order.last { #expect(path == "Direct (LAN)") } else { Issue.record("expected connected, got \(String(describing: order.last))") }

        try await E2E.waitUntil(timeoutMs: 15000, "video frames") { renderer.frames.get() >= 5 }
        // libwebrtc ramps resolution up with its bandwidth estimate, so early frames can be smaller than 1280x720.
        let size = renderer.size.get()
        #expect(size.width > 0 && size.height > 0)
        #expect(abs(size.width / size.height - 16.0 / 9.0) < 0.05, "aspect ratio preserved: \(size)")
        try await E2E.waitUntil(timeoutMs: 5000, "rtt") { !rtts.get().isEmpty }
        #expect(rtts.get()[0] >= 0 && rtts.get()[0] < 1000)
        #expect(displays.get().first?.width_px == 1280)
        #expect(await session.currentDisplay?.display_id == "0")

        // Input is accepted by the host even though injection is disabled in this test.
        await session.send(.mouseMove(displayId: "0", x: 0.5, y: 0.5))
        await session.send(.keyDown(code: "KeyA", modifiers: [], repeat: false))
        await session.send(.keyUp(code: "KeyA", modifiers: []))

        await session.disconnect()
        try await E2E.waitUntil("host saw the end") {
            agentEvents.get().contains { if case .sessionEnded(.user) = $0 { return true } else { return false } }
        }
        if case .ended = await session.state {} else { Issue.record("session should be ended") }
        await agent.stop()
    }

    /// A duplicate or late SDP_ANSWER used to end the session with "Called in wrong state: stable".
    /// On a lossy relay the reconnect loop could issue a second offer before the first was answered,
    /// so this happened in ordinary use.
    @Test func aSecondAnswerDoesNotKillTheSession() async throws {
        let (agent, _) = try await E2E.startAgent(media: true)
        let identity = SoftwareIdentity()
        let qr = await agent.coordinator.openPairing()
        let outcome = try await PairingClient(identity: identity, deviceName: "T").pair(qr: qr, preferredAddress: "127.0.0.1:\(agent.port)")

        let session = SessionClient(.init(identity: identity, host: outcome.host, config: ControllerConfig(deviceName: "T", dataDirectory: E2E.tempDir())))
        let states = Box<[SessionClient.State]>([])
        let stream = session.events
        Task { for await e in stream { if case .state(let s) = e { states.update { $0.append(s) } } } }
        await session.connect(url: Endpoints.url(for: "127.0.0.1:\(agent.port)")!)
        try await E2E.waitUntil(timeoutMs: 20000, "connected") {
            states.get().contains { if case .connected = $0 { return true } else { return false } }
        }

        // Replay the answer the host already sent. The old code applied it and ended the session.
        await session.replayLastAnswerForTest()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        if case .connected = await session.state {} else {
            Issue.record("a duplicate answer ended the session: \(await session.state)")
        }
        await session.disconnect()
        await agent.stop()
    }

    @Test func unpairedControllerIsRejected() async throws {
        let (agent, _) = try await E2E.startAgent(media: false)
        let identity = SoftwareIdentity()
        let host = Peer(deviceId: agent.identity.deviceId, publicKey: agent.identity.publicKeyB64, name: "Test Mini", type: .mac, weMayControl: true, pairedAt: 0)
        let session = SessionClient(.init(identity: identity, host: host, config: ControllerConfig(deviceName: "Stranger", dataDirectory: E2E.tempDir())))
        let states = Box<[SessionClient.State]>([])
        let stream = session.events
        Task { for await e in stream { if case .state(let s) = e { states.update { $0.append(s) } } } }
        await session.connect(url: Endpoints.url(for: "127.0.0.1:\(agent.port)")!)
        try await E2E.waitUntil("rejected") {
            states.get().contains { if case .ended(let r) = $0 { return r.contains("untrusted") } else { return false } }
        }
        await agent.stop()
    }

    /// Connecting to a Mac other than the one we paired with: the agent drops every envelope as
    /// wrong_recipient without replying, so only the handshake watchdog ends the attempt.
    @Test func mismatchedHostIdentityTimesOutWithAdvice() async throws {
        let (agent, _) = try await E2E.startAgent(media: false)
        let identity = SoftwareIdentity()
        let impostor = SoftwareIdentity()
        // A paired host record whose device id is not the agent's.
        let host = Peer(deviceId: impostor.deviceId, publicKey: impostor.publicKeyB64, name: "Wrong Mac", type: .mac, weMayControl: true, pairedAt: 0)
        let config = ControllerConfig(deviceName: "T", dataDirectory: E2E.tempDir(), authTimeoutSeconds: 2)
        let session = SessionClient(.init(identity: identity, host: host, config: config))
        let states = Box<[SessionClient.State]>([])
        let stream = session.events
        Task { for await e in stream { if case .state(let s) = e { states.update { $0.append(s) } } } }
        await session.connect(url: Endpoints.url(for: "127.0.0.1:\(agent.port)")!)

        try await E2E.waitUntil(timeoutMs: 12000, "handshake timeout") {
            states.get().contains { if case .ended = $0 { return true } else { return false } }
        }
        #expect(states.get().contains(.authenticating), "the socket opens, so we do reach authenticating")
        guard case .ended(let reason)? = states.get().last else { Issue.record("expected ended"); return }
        #expect(reason.contains("did not answer"), "\(reason)")
        #expect(reason.contains("Remote Access"), "the message should say what to check: \(reason)")
        await agent.stop()
    }

    @Test func unreachableHostEndsCleanly() async throws {
        let identity = SoftwareIdentity()
        let host = Peer(deviceId: String(repeating: "ab", count: 32), publicKey: String(repeating: "A", count: 87), name: "Ghost", type: .mac, weMayControl: true, pairedAt: 0)
        let session = SessionClient(.init(identity: identity, host: host, config: ControllerConfig(deviceName: "X", dataDirectory: E2E.tempDir())))
        let states = Box<[SessionClient.State]>([])
        let stream = session.events
        Task { for await e in stream { if case .state(let s) = e { states.update { $0.append(s) } } } }
        await session.connect(url: Endpoints.url(for: "127.0.0.1:1")!)
        try await E2E.waitUntil(timeoutMs: 15000, "ended") {
            states.get().contains { if case .ended = $0 { return true } else { return false } }
        }
    }
}
