import Foundation
import PRCIdentity
import PRCPeers
import PRCProtocol
import Testing
import WebRTC
@testable import PRCAgentCore

final class RecordingServerDelegate: SignalingServerDelegate, @unchecked Sendable {
    let lock = NSLock()
    var received: [(ConnectionID, String)] = []
    var opened: [ConnectionID] = []
    var closed: [ConnectionID] = []
    func signaling(_ server: SignalingServer, didOpen id: ConnectionID, remote: String) { lock.lock(); opened.append(id); lock.unlock() }
    func signaling(_ server: SignalingServer, didReceive text: String, from id: ConnectionID) { lock.lock(); received.append((id, text)); lock.unlock() }
    func signaling(_ server: SignalingServer, didClose id: ConnectionID) { lock.lock(); closed.append(id); lock.unlock() }
}

@Suite struct SignalingServerTests {
    @Test func webSocketRoundTripOnLocalhost() async throws {
        let server = SignalingServer(port: 0, advertisement: nil)
        let delegate = RecordingServerDelegate()
        server.delegate = delegate
        let ready = LockedValue<UInt16>(0)
        server.onReady = { ready.set($0) }
        try server.start()
        try await waitUntil("listener ready") { ready.get() != 0 }

        let url = URL(string: "ws://127.0.0.1:\(ready.get())/")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        try await task.send(.string("hello from client"))
        try await waitUntil("server received") { delegate.lock.lock(); defer { delegate.lock.unlock() }; return delegate.received.count == 1 }
        let (id, text) = delegate.received[0]
        #expect(text == "hello from client")

        server.send("hello from server", to: id)
        let reply = try await task.receive()
        if case .string(let s) = reply { #expect(s == "hello from server") } else { Issue.record("expected text frame") }

        task.cancel(with: .normalClosure, reason: nil)
        try await waitUntil("server saw close") { delegate.lock.lock(); defer { delegate.lock.unlock() }; return delegate.closed.contains(id) }
        server.stop()
    }

    @Test func agentStartsWithFileIdentityAndAnswersOverWebSocket() async throws {
        let dir = tempDirectory()
        var config = AgentConfig(hostName: "Test Mini", port: 0, advertiseBonjour: false, dataDirectory: dir, mediaEnabled: false, inputEnabled: false)
        config.identityFile = dir.appendingPathComponent("identity.key")
        let agent = try Agent(config: config)
        try agent.start()
        try await waitUntil("agent port") { agent.port != 0 }

        // A second Agent from the same directory must load the same identity.
        #expect(try FileBackedIdentityStore.loadOrCreate(at: config.identityFile!).deviceId == agent.identity.deviceId)

        let controller = TestController(hostPublicKey: agent.identity.publicKeyRaw, now: { nowMs() })
        try agent.peers.pair(deviceId: controller.deviceId, publicKey: controller.identity.publicKeyB64, name: "T",
                             type: .web, mayControlUs: true, weMayControl: false, now: 0)

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(agent.port)/")!)
        task.resume()
        try await task.send(.string(try controller.text(Harness.request, to: agent.identity.deviceId, session: "")))
        let reply = try await task.receive()
        guard case .string(let text) = reply else { Issue.record("expected text"); return }
        let env = try JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
        let accepted = try controller.accept([env])
        guard case .sessionChallenge(let challenge) = accepted[0].1 else { Issue.record("expected SESSION_CHALLENGE over the wire"); return }
        #expect(challenge.client_nonce == "AAECAwQFBgcICQoLDA0ODw")
        task.cancel(with: .normalClosure, reason: nil)
        await agent.stop()
    }
}

/// The controller side of a loopback, built straight on libwebrtc.
final class LoopbackController: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    var pc: RTCPeerConnection!
    var channels: [ChannelLabel: RTCDataChannel] = [:]
    let lock = NSLock()
    var candidates: [RTCIceCandidate] = []
    var received: [DataChannelFrame] = []
    var openLabels: Set<ChannelLabel> = []
    var remoteTracks = 0

    override init() {
        super.init()
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        pc = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        pc.addTransceiver(of: .video, init: transceiverInit)
        for label in ChannelLabel.allCases {
            let cfg = RTCDataChannelConfiguration()
            cfg.isOrdered = label.ordered
            if let r = label.maxRetransmits { cfg.maxRetransmits = Int32(r) }
            let ch = pc.dataChannel(forLabel: label.rawValue, configuration: cfg)!
            ch.delegate = self
            channels[label] = ch
        }
    }

    func offer() async throws -> String {
        let sdp: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? TestError.rejected("offer")) }
            }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in error.map { c.resume(throwing: $0) } ?? c.resume() }
        }
        return sdp.sdp
    }

    func setAnswer(_ sdp: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in error.map { c.resume(throwing: $0) } ?? c.resume() }
        }
    }

    func send(_ message: DataChannelMessage) {
        let data = try! DataChannelCodec.encode(message, ts: 1)
        channels[message.channel]!.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        lock.lock(); remoteTracks += 1; lock.unlock()
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        lock.lock(); candidates.append(candidate); lock.unlock()
    }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open, let label = ChannelLabel(rawValue: dataChannel.label) { lock.lock(); openLabels.insert(label); lock.unlock() }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if let frame = try? DataChannelCodec.decode(buffer.data) { lock.lock(); received.append(frame); lock.unlock() }
    }
}

final class RecordingWebRTCDelegate: WebRTCSessionDelegate, @unchecked Sendable {
    let lock = NSLock()
    var candidates: [IceCandidatePayload] = []
    var states: [RTCPeerConnectionState] = []
    var frames: [DataChannelFrame] = []
    var rejected: [DataChannelError] = []
    var open: Set<ChannelLabel> = []
    func webrtc(_ session: WebRTCSession, didGenerateCandidate candidate: IceCandidatePayload) { lock.lock(); candidates.append(candidate); lock.unlock() }
    func webrtc(_ session: WebRTCSession, didChangeConnectionState state: RTCPeerConnectionState) { lock.lock(); states.append(state); lock.unlock() }
    func webrtc(_ session: WebRTCSession, didOpenChannel label: ChannelLabel) { lock.lock(); open.insert(label); lock.unlock() }
    func webrtc(_ session: WebRTCSession, didReceive frame: DataChannelFrame, on label: ChannelLabel) { lock.lock(); frames.append(frame); lock.unlock() }
    func webrtc(_ session: WebRTCSession, didRejectMessage error: DataChannelError, on label: String) { lock.lock(); rejected.append(error); lock.unlock() }
}

@Suite struct WebRTCLoopbackTests {
    /// Real libwebrtc on both ends, in process, no capture. Proves the answerer plumbing, ICE, and data channels.
    @Test func hostAnswersAndDataChannelsFlowBothWays() async throws {
        let host = try WebRTCSession(iceServers: [], maxBitrateBps: 20_000_000, maxFramerate: 60)
        let hostDelegate = RecordingWebRTCDelegate()
        host.delegate = hostDelegate
        let controller = LoopbackController()

        let offer = try await controller.offer()
        #expect(offer.contains("m=video"))
        #expect(offer.contains("m=application"))
        let answer = try await host.answerOfferForTest(offer)
        #expect(answer.contains("m=video"))
        try await controller.setAnswer(answer)

        // Trickle ICE both ways.
        try await waitUntil("candidates") {
            controller.lock.lock(); defer { controller.lock.unlock() }
            hostDelegate.lock.lock(); defer { hostDelegate.lock.unlock() }
            return !controller.candidates.isEmpty && !hostDelegate.candidates.isEmpty
        }
        var fedToHost = 0, fedToController = 0
        try await waitUntil(timeoutMs: 15000, "connected") {
            controller.lock.lock(); let cc = controller.candidates; controller.lock.unlock()
            hostDelegate.lock.lock(); let hc = hostDelegate.candidates; let states = hostDelegate.states; hostDelegate.lock.unlock()
            while fedToHost < cc.count {
                let c = cc[fedToHost]
                host.add(candidate: IceCandidatePayload(candidate: c.sdp, sdp_mid: c.sdpMid, sdp_mline_index: Int(c.sdpMLineIndex)))
                fedToHost += 1
            }
            while fedToController < hc.count {
                let c = hc[fedToController]
                controller.pc.add(RTCIceCandidate(sdp: c.candidate, sdpMLineIndex: Int32(c.sdp_mline_index ?? 0), sdpMid: c.sdp_mid)) { _ in }
                fedToController += 1
            }
            return states.contains(.connected)
        }

        try await waitUntil(timeoutMs: 10000, "channels open") {
            controller.lock.lock(); defer { controller.lock.unlock() }
            hostDelegate.lock.lock(); defer { hostDelegate.lock.unlock() }
            return controller.openLabels.count == 3 && hostDelegate.open.count == 3
        }
        #expect(controller.remoteTracks == 1, "the screen track is offered to the controller")

        controller.send(.ping(nonce: 9))
        controller.send(.mouseMove(displayId: "1", x: 0.25, y: 0.75))
        controller.channels[.inputLossy]!.sendData(RTCDataBuffer(data: Data("{\"v\":1,\"type\":\"key_down\",\"ts\":1,\"code\":\"KeyA\",\"modifiers\":[],\"repeat\":false}".utf8), isBinary: false))
        try await waitUntil("host received") { hostDelegate.lock.lock(); defer { hostDelegate.lock.unlock() }; return hostDelegate.frames.count == 2 && hostDelegate.rejected.count == 1 }
        #expect(hostDelegate.frames.map(\.message).contains(.ping(nonce: 9)))
        #expect(hostDelegate.frames.map(\.message).contains(.mouseMove(displayId: "1", x: 0.25, y: 0.75)))
        #expect(hostDelegate.rejected == [.wrongChannel(expected: .inputReliable)])

        host.send(.pong(nonce: 9), ts: 2)
        host.send(.displayInfo(DisplayInfo(display_id: "1", width_px: 1920, height_px: 1080, scale: 1)), ts: 3)
        try await waitUntil("controller received") { controller.lock.lock(); defer { controller.lock.unlock() }; return controller.received.count == 2 }
        #expect(controller.received.map(\.message).contains(.pong(nonce: 9)))

        let path = await withCheckedContinuation { c in host.selectedPath { c.resume(returning: $0) } }
        #expect(path == "Direct (LAN)")

        host.close()
        controller.pc.close()
    }
}

extension WebRTCSession {
    func answerOfferForTest(_ offer: String) async throws -> String { try await answer(offerSDP: offer) }
}

@Suite struct MediaPolicyTests {
    @Test func relayedPathsGetAConservativeStartAndHalfTheFrames() {
        // Seeding a LAN bitrate on a relayed link overshoots it: the encoder collapses to a soft
        // picture and the queue adds latency. Declaring the real path is what prevents that.
        let lan = WebRTCSession.bitrates(for: .lan, cap: 20_000_000)
        let cloud = WebRTCSession.bitrates(for: .cloud, cap: 20_000_000)
        #expect(lan.min == 1_000_000 && lan.start == 6_000_000 && lan.max == 20_000_000)
        #expect(cloud.min == 600_000 && cloud.start == 1_500_000 && cloud.max == 8_000_000)
        #expect(cloud.start < lan.start && cloud.max < lan.max)
        #expect(cloud.min > 0, "a floor keeps a still screen from starving the estimate to nothing")

        #expect(WebRTCSession.framerate(for: .lan, cap: 60) == 60)
        #expect(WebRTCSession.framerate(for: .cloud, cap: 60) == 30)
        #expect(WebRTCSession.framerate(for: .cloud, cap: 24) == 24, "never raise the configured cap")
        let tiny = WebRTCSession.bitrates(for: .lan, cap: 3_000_000)
        #expect(tiny.start == 3_000_000 && tiny.max == 3_000_000, "never exceed the cap")
    }

    @Test func requestedHeightBecomesAScaleFactor() {
        // libwebrtc scales by a divisor, not to a target height.
        #expect(WebRTCSession.scaleFactor(captureHeight: 1080, maxHeight: 540) == 2)
        #expect(WebRTCSession.scaleFactor(captureHeight: 1080, maxHeight: 720) == 1.5)
        #expect(WebRTCSession.scaleFactor(captureHeight: 1080, maxHeight: 1080) == 1)
        #expect(WebRTCSession.scaleFactor(captureHeight: 1080, maxHeight: nil) == 1, "automatic")
        #expect(WebRTCSession.scaleFactor(captureHeight: 720, maxHeight: 1080) == 1, "never upscale")
        #expect(WebRTCSession.scaleFactor(captureHeight: 0, maxHeight: 540) == 1, "no capture size yet")
    }

    @Test func moveGateDropsReorderedAbsoluteMoves() {
        var gate = MoveOrderGate()
        // Sender timestamps as they might arrive after reordering on a relayed link.
        let accepted = [10, 20, 15, 19, 20, 21].map { gate.accept(Int64($0)) }
        #expect(accepted == [true, true, false, false, true, true],
                "15 and 19 left the controller before 20 and must not move the cursor backwards")
        gate.reset()
        let afterReset = gate.accept(1)
        #expect(afterReset, "a new session restarts sender time at zero")
    }
}

@Suite struct PathClassificationTests {
    @Test func classifiesByTypeAndAddress() {
        #expect(WebRTCSession.classifyPath(localType: "host", remoteType: "host", localAddress: "192.168.1.2", remoteAddress: "192.168.1.3") == "Direct (LAN)")
        #expect(WebRTCSession.classifyPath(localType: "host", remoteType: "prflx", localAddress: "192.168.1.2", remoteAddress: "192.168.1.3") == "Direct (LAN)")
        #expect(WebRTCSession.classifyPath(localType: "host", remoteType: "prflx", localAddress: "100.80.1.2", remoteAddress: "100.80.1.3") == "Direct (Tailscale)")
        #expect(WebRTCSession.classifyPath(localType: "relay", remoteType: "host", localAddress: "100.80.1.2", remoteAddress: "100.80.1.3") == "Relayed", "a real TURN relay still wins")
        #expect(WebRTCSession.classifyPath(localType: "srflx", remoteType: "srflx", localAddress: "203.0.113.5", remoteAddress: "198.51.100.7") == "Direct (Internet)")
        #expect(WebRTCSession.classifyPath(localType: "host", remoteType: "prflx", localAddress: "192.168.1.2", remoteAddress: "") == "Direct (LAN)", "prflx remote without an address, reached on our private host candidate")
        #expect(WebRTCSession.classifyPath(localType: "srflx", remoteType: "prflx", localAddress: "203.0.113.5", remoteAddress: "") == "Direct (Internet)")
        #expect(WebRTCSession.classifyPath(localType: "relay", remoteType: "host", localAddress: "203.0.113.5", remoteAddress: "192.168.1.3") == "Relayed")
        #expect(WebRTCSession.isPrivateAddress("172.20.0.1") && !WebRTCSession.isPrivateAddress("172.40.0.1"))
        #expect(WebRTCSession.isPrivateAddress("fd7a:115c:a1e0::1") && !WebRTCSession.isPrivateAddress("2001:db8::1"))
        #expect(WebRTCSession.classifyPath(localType: "host", remoteType: "host", localAddress: "fd7a:115c:a1e0::1", remoteAddress: "fd7a:115c:a1e0::2") == "Direct (Tailscale)")
        #expect(WebRTCSession.isOverlayAddress("fd7a:115c:a1e0::1") && !WebRTCSession.isOverlayAddress("fd00::1"))
    }
}
