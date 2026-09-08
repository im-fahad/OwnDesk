import Foundation
import Network
import PRCIdentity
import PRCProtocol
import WebRTC

/// The controller's session state machine (spec sections 8, 10, 13): authenticate, negotiate,
/// keep alive, and reconnect without ever skipping verification.
public actor SessionClient {
    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case authenticating
        case negotiating
        case connected(path: String)
        case reconnecting(String)
        case ended(String)
    }

    public enum Event: Sendable {
        case state(State)
        case display(DisplayInfo)
        case rtt(Double)
        case remoteVideo
        case log(String)
    }

    public struct Dependencies: Sendable {
        public var identity: any SigningIdentity
        public var host: PairedHost
        public var config: ControllerConfig
        public var iceServerURLs: [String]
        public var now: @Sendable () -> Int64

        public init(identity: any SigningIdentity, host: PairedHost, config: ControllerConfig, iceServerURLs: [String] = [], now: @escaping @Sendable () -> Int64 = { nowMs() }) {
            self.identity = identity; self.host = host; self.config = config; self.iceServerURLs = iceServerURLs; self.now = now
        }
    }

    private nonisolated let deps: Dependencies
    private var sender: EnvelopeSender
    private var receiver: EnvelopeReceiver
    private var signaling: SignalingClient?
    private var signalingUp = false
    private var url: URL?
    private var sessionId = ""
    private var clientNonce = ""
    private var hostNonce = ""
    private var webrtc: WebRTCClient?
    private let bridge = ClientBridge()
    private let inbound = OrderedExecutor()
    private var pendingRenderers: [RTCVideoRenderer] = []
    private var display: DisplayInfo?
    private var mediaUp = false
    private var ended = false
    private var resumeInFlight = false
    private var lastPath = "Direct"
    private var pingTask: Task<Void, Never>?
    private var outstandingPings: [UInt32: Int64] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var reconnectStartedAt: Int64?
    private var handshakeTask: Task<Void, Never>?
    private var mediaStartedAt: Int64 = 0
    public private(set) var state: State = .idle

    private let eventContinuation: AsyncStream<Event>.Continuation
    public nonisolated let events: AsyncStream<Event>

    public init(_ deps: Dependencies) {
        self.deps = deps
        sender = EnvelopeSender(identity: deps.identity, now: deps.now)
        let hostId = deps.host.deviceId
        let hostKey = deps.host.publicKeyRaw
        receiver = EnvelopeReceiver(selfDeviceId: deps.identity.deviceId, resolveKey: { $0 == hostId ? hostKey : nil }, now: deps.now)
        var continuation: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        eventContinuation = continuation
        bridge.session = self
    }

    public var currentDisplay: DisplayInfo? { display }
    public nonisolated var hostName: String { deps.host.name }

    private func now() -> Int64 { deps.now() }
    private func emit(_ event: Event) { eventContinuation.yield(event) }
    private func setState(_ s: State) { state = s; emit(.state(s)) }
    private func log(_ text: String) { Log.session.notice("\(text, privacy: .public)"); emit(.log(text)) }

    // MARK: Public API

    public func connect(url: URL) {
        switch state {
        case .idle, .ended: break
        default: return
        }
        ended = false
        sessionId = ""
        self.url = url
        setState(.connecting)
        openSignaling()
    }

    public func disconnect() {
        guard !ended else { return }
        webrtc?.send(.bye(.user), ts: elapsed())
        if signalingUp, !sessionId.isEmpty { send(.sessionEnd(SessionEndPayload(reason: .user)), session: sessionId) }
        end("disconnected")
    }

    /// Input and control messages. Dropped silently until the data channels are open.
    public func send(_ message: DataChannelMessage) {
        webrtc?.send(message, ts: elapsed())
    }

    /// Measured inbound video, for diagnosing a soft picture. Nil when no media is running.
    public func videoStats() async -> WebRTCClient.InboundVideoStats? {
        guard let webrtc else { return nil }
        return await withCheckedContinuation { c in
            webrtc.inboundVideoStats { c.resume(returning: $0) }
        }
    }

    public func attach(renderer: RTCVideoRenderer) {
        if let webrtc { webrtc.attach(renderer: renderer) } else { pendingRenderers.append(renderer) }
    }

    public func detach(renderer: RTCVideoRenderer) {
        pendingRenderers.removeAll { $0 === renderer }
        webrtc?.detach(renderer: renderer)
    }

    // MARK: Signaling

    private func openSignaling() {
        guard let url else { return }
        let client = SignalingClient(url: url)
        let inbound = self.inbound
        client.onEvent = { [weak self] event in
            guard let self else { return }
            inbound.enqueue { await self.handleSignaling(event, from: client) }
        }
        signaling = client
        client.connect()
    }

    private func handleSignaling(_ event: SignalingClient.Event, from client: SignalingClient) async {
        guard client === signaling else { return }
        switch event {
        case .opened:
            signalingUp = true
            if sessionId.isEmpty {
                sendSessionRequest()
            } else {
                resumeInFlight = true
                send(.sessionResume(SessionResumePayload()), session: sessionId)
            }
        case .message(let text):
            await handleText(text)
        case .closed(let reason):
            signalingUp = false
            signaling = nil
            if !ended {
                if sessionId.isEmpty, case .connecting = state {
                    end("cannot reach \(deps.host.name): \(reason ?? "connection closed")")
                } else {
                    scheduleReconnect(reason ?? "signaling closed")
                }
            }
        }
    }

    /// The path the host uses to size its bitrate (spec section 16). An overlay address such as
    /// Tailscale's is private but may be relayed halfway around the world, so it is `cloud`: seeding
    /// a LAN bitrate there overshoots the link, and the encoder collapses to a blurry picture.
    var declaredPath: ConnectionPath { SessionClient.path(forHost: url?.host) }

    static func path(forHost host: String?) -> ConnectionPath {
        guard let host else { return .cloud }
        if PathClassifier.isOverlay(host) { return .cloud }
        return PathClassifier.isPrivate(host) ? .lan : .cloud
    }

    private func sendSessionRequest() {
        clientNonce = Base64URL.encode(Pairing.randomSecret())
        forgetAttempt()
        setState(.authenticating)
        startHandshakeWatchdog(seconds: deps.config.authTimeoutSeconds, phase: "authenticating")
        let request = SessionRequestPayload(client_nonce: clientNonce, versions: Envelope.supportedVersions, path: declaredPath,
                                            capabilities: SessionCapabilities(codecs: [.h264], max_height: 1080, max_fps: 60))
        send(.sessionRequest(request), session: "")
    }

    private func handleText(_ text: String) async {
        switch receiver.receive(Data(text.utf8)) {
        case .rejected(let reason, let detail):
            log("dropped inbound \(reason.rawValue) \(detail ?? "")")
        case .accepted(let env, let payload, _):
            switch payload {
            case .sessionChallenge(let c):
                guard env.session == c.session_id, c.client_nonce == clientNonce else { end("challenge mismatch"); return }
                sessionId = c.session_id
                hostNonce = c.host_nonce
                forgetAttempt()
                send(.sessionAuth(SessionAuthPayload(client_nonce: clientNonce, host_nonce: hostNonce)), session: sessionId)
            case .sessionReject(let r):
                forgetAttempt()
                if resumeInFlight, r.reason == .expired {
                    // Resume window passed: full re-authentication, no re-pairing (spec section 10).
                    resumeInFlight = false
                    receiver.forgetSession(from: deps.host.deviceId, session: sessionId)
                    sender.forgetSession(to: deps.host.deviceId, session: sessionId)
                    sessionId = ""
                    closeMedia()
                    sendSessionRequest()
                } else {
                    end("rejected: \(r.reason.rawValue)")
                }
            case .sessionAccept(let a):
                guard env.session == sessionId, a.client_nonce == clientNonce, a.host_nonce == hostNonce else { end("accept mismatch"); return }
                display = a.display
                emit(.display(a.display))
                if resumeInFlight {
                    resumeInFlight = false
                    if mediaUp { setState(.connected(path: lastPath)) } else { await restartIce() }
                } else {
                    setState(.negotiating)
                    startHandshakeWatchdog(seconds: deps.config.negotiateTimeoutSeconds, phase: "negotiating")
                    await startMedia()
                }
            case .sdpAnswer(let a):
                guard env.session == sessionId else { return }
                do { try await webrtc?.setAnswer(a.sdp) } catch { end("answer rejected: \(error)") }
            case .iceCandidate(let c):
                guard env.session == sessionId else { return }
                webrtc?.add(candidate: c)
            case .sessionEnd(let e):
                guard env.session == sessionId else { return }
                end("host ended the session: \(e.reason.rawValue)")
            case .pairRequest, .pairResult, .sessionRequest, .sessionAuth, .sdpOffer, .sessionResume:
                log("ignoring host-bound type \(env.type)")
            }
        }
    }

    private func send(_ payload: SignalingPayload, session: String) {
        guard let signaling else { return }
        do {
            let env = try sender.build(payload, to: deps.host.deviceId, session: session)
            signaling.send(String(decoding: try env.serialized(), as: UTF8.self))
        } catch {
            log("failed to send \(payload.type.rawValue): \(error)")
        }
    }

    private func forgetAttempt() {
        sender.forgetSession(to: deps.host.deviceId, session: "")
        receiver.forgetSession(from: deps.host.deviceId, session: "")
    }

    // MARK: Media

    private func startMedia() async {
        do {
            let client = try WebRTCClient(iceServers: deps.iceServerURLs.isEmpty ? [] : [RTCIceServer(urlStrings: deps.iceServerURLs)])
            client.delegate = bridge
            webrtc = client
            mediaStartedAt = now()
            for r in pendingRenderers { client.attach(renderer: r) }
            pendingRenderers.removeAll()
            let sdp = try await client.offer(iceRestart: false)
            send(.sdpOffer(SdpOfferPayload(sdp: sdp, ice_restart: false)), session: sessionId)
        } catch {
            end("webrtc failed: \(error)")
        }
    }

    private func restartIce() async {
        guard let webrtc else { await startMedia(); return }
        do {
            let sdp = try await webrtc.offer(iceRestart: true)
            send(.sdpOffer(SdpOfferPayload(sdp: sdp, ice_restart: true)), session: sessionId)
        } catch {
            log("ice restart failed: \(error)")
        }
    }

    private func closeMedia() {
        stopPing()
        webrtc?.close()
        webrtc = nil
        mediaUp = false
    }

    private func elapsed() -> Int64 { max(0, now() - mediaStartedAt) }

    func mediaCandidate(_ candidate: IceCandidatePayload) {
        guard !ended else { return }
        send(.iceCandidate(candidate), session: sessionId)
    }

    func mediaConnectionState(_ s: RTCPeerConnectionState) async {
        guard !ended else { return }
        switch s {
        case .connected:
            mediaUp = true
            cancelHandshakeWatchdog()
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectStartedAt = nil
            let path: String? = await withCheckedContinuation { c in
                if let webrtc { webrtc.selectedPath { c.resume(returning: $0) } } else { c.resume(returning: nil) }
            }
            lastPath = path ?? "Direct"
            setState(.connected(path: lastPath))
            startPing()
        case .disconnected, .failed:
            mediaUp = false
            stopPing()
            scheduleReconnect("media \(s == .failed ? "failed" : "disconnected")")
        case .closed:
            mediaUp = false
        default:
            break
        }
    }

    func mediaChannelOpened(_ label: ChannelLabel) {
        guard label == .control else { return }
        webrtc?.send(.hello(versions: Envelope.supportedVersions, app: .macController, appVersion: "0.1.0"), ts: elapsed())
    }

    func mediaFrame(_ frame: DataChannelFrame) {
        switch frame.message {
        case .displayInfo(let d):
            display = d
            emit(.display(d))
        case .pong(let nonce):
            if let sent = outstandingPings.removeValue(forKey: nonce) {
                outstandingPings.removeAll()
                emit(.rtt(Double(now() - sent)))
            }
        case .bye(let reason):
            end("host ended the session: \(reason.rawValue)")
        default:
            break
        }
    }

    func mediaRemoteVideo() {
        emit(.remoteVideo)
    }

    // MARK: Keepalive

    private func startPing() {
        stopPing()
        let interval = UInt64(deps.config.pingIntervalMs) * 1_000_000
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await self?.pingTick()
            }
        }
    }

    private func stopPing() {
        pingTask?.cancel()
        pingTask = nil
        outstandingPings.removeAll()
    }

    private func pingTick() {
        guard mediaUp, let webrtc, !ended else { return }
        if outstandingPings.count >= deps.config.missedPongsBeforeReconnect {
            outstandingPings.removeAll()
            scheduleReconnect("host stopped answering pings")
            return
        }
        let nonce = UInt32.random(in: 0...UInt32.max)
        outstandingPings[nonce] = now()
        webrtc.send(.ping(nonce: nonce), ts: elapsed())
    }

    // MARK: Reconnection (spec section 10)

    private func scheduleReconnect(_ why: String) {
        guard !ended, reconnectTask == nil else { return }
        if reconnectStartedAt == nil { reconnectStartedAt = now() }
        setState(.reconnecting(why))
        reconnectTask = Task { [weak self] in await self?.reconnectLoop() }
    }

    private func reconnectLoop() async {
        var delayMs: UInt64 = 500
        while !ended, !Task.isCancelled {
            if let started = reconnectStartedAt, now() - started > Int64(deps.config.reconnectWindowSeconds) * 1000 {
                end("could not reconnect within \(deps.config.reconnectWindowSeconds) s")
                return
            }
            if !signalingUp {
                if signaling == nil { openSignaling() }
            } else if !mediaUp, !resumeInFlight {
                await restartIce()
            }
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            if mediaUp, signalingUp { break }
            delayMs = min(delayMs * 2, 5000)
        }
        reconnectTask = nil
        reconnectStartedAt = nil
    }

    /// Without this a host that never answers leaves the controller in `authenticating` forever with
    /// no way out. The commonest cause is connecting to a Mac other than the one this controller is
    /// paired with: the agent drops messages addressed to a different device id without replying.
    private func startHandshakeWatchdog(seconds: Int, phase: String) {
        cancelHandshakeWatchdog()
        let deadline = UInt64(max(seconds, 1)) * 1_000_000_000
        handshakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: deadline)
            guard !Task.isCancelled else { return }
            await self?.handshakeTimedOut(phase: phase, seconds: seconds)
        }
    }

    private func cancelHandshakeWatchdog() {
        handshakeTask?.cancel()
        handshakeTask = nil
    }

    private func handshakeTimedOut(phase: String, seconds: Int) {
        guard !ended, !mediaUp else { return }
        switch state {
        case .authenticating:
            end("\(deps.host.name) did not answer within \(seconds) s. Check that this address is the Mac you paired with, that it is awake, and that Remote Access is on.")
        case .negotiating:
            end("connected to \(deps.host.name) but the video link did not come up within \(seconds) s.")
        default:
            break
        }
    }

    private func end(_ reason: String) {
        guard !ended else { return }
        ended = true
        cancelHandshakeWatchdog()
        reconnectTask?.cancel()
        reconnectTask = nil
        closeMedia()
        signaling?.close()
        signaling = nil
        signalingUp = false
        resumeInFlight = false
        setState(.ended(reason))
    }
}

/// Hops WebRTC callbacks into the actor, preserving their order.
final class ClientBridge: WebRTCClientDelegate, @unchecked Sendable {
    weak var session: SessionClient?
    private let queue = OrderedExecutor()
    func webrtc(_ client: WebRTCClient, didGenerateCandidate candidate: IceCandidatePayload) { queue.enqueue { [weak self] in await self?.session?.mediaCandidate(candidate) } }
    func webrtc(_ client: WebRTCClient, didChangeConnectionState state: RTCPeerConnectionState) { queue.enqueue { [weak self] in await self?.session?.mediaConnectionState(state) } }
    func webrtc(_ client: WebRTCClient, didOpenChannel label: ChannelLabel) { queue.enqueue { [weak self] in await self?.session?.mediaChannelOpened(label) } }
    func webrtc(_ client: WebRTCClient, didReceive frame: DataChannelFrame, on label: ChannelLabel) { queue.enqueue { [weak self] in await self?.session?.mediaFrame(frame) } }
    func webrtcDidReceiveRemoteVideo(_ client: WebRTCClient) { queue.enqueue { [weak self] in await self?.session?.mediaRemoteVideo() } }
}
