import Foundation
import PRCIdentity
import PRCProtocol

/// The host's brain: verifies every envelope, runs pairing and session authentication, and drives media.
/// One active controller at a time (spec sections 7, 8, 20, 21).
public actor SessionCoordinator {
    public struct Dependencies: Sendable {
        public var identity: any SigningIdentity
        public var trust: TrustStore
        public var config: AgentConfig
        public var transport: any SignalingTransport
        public var mediaFactory: MediaSessionFactory?
        public var input: (any InputSink)?
        public var power: PowerAssertion?
        public var now: @Sendable () -> Int64

        public init(identity: any SigningIdentity, trust: TrustStore, config: AgentConfig, transport: any SignalingTransport,
                    mediaFactory: MediaSessionFactory? = nil, input: (any InputSink)? = nil, power: PowerAssertion? = nil,
                    now: @escaping @Sendable () -> Int64 = { nowMs() }) {
            self.identity = identity; self.trust = trust; self.config = config; self.transport = transport
            self.mediaFactory = mediaFactory; self.input = input; self.power = power; self.now = now
        }
    }

    enum SessionState { case challenged, authenticated, connected }

    struct HostSession {
        let id: String
        let deviceId: String
        let deviceName: String
        let clientNonce: String
        let hostNonce: String
        let expiresAt: Int64
        let path: ConnectionPath
        var state: SessionState
        var connection: ConnectionID?
        var signalingUp = true
        var mediaUp = false
        var lastActivity: Int64
        var lastInput: Int64
        var media: MediaSession?
        var display: MediaDisplay
        var malformedCount = 0
        var malformedWindowStart: Int64
    }

    struct PendingPairing {
        let deviceId: String
        let publicKey: String
        let name: String
        let type: DeviceType
        let connection: ConnectionID
    }

    struct PairingState {
        let sessionId: String
        let code: Data
        let qr: QRPayload
        var failures = 0
        var pending: PendingPairing?
    }

    private nonisolated let deps: Dependencies
    private var sender: EnvelopeSender
    private var receiver: EnvelopeReceiver
    private var connections: [ConnectionID: String] = [:]
    private var deviceConnections: [String: ConnectionID] = [:]
    private var pairing: PairingState?
    private var session: HostSession?
    private var lastRejectAt: [String: Int64] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var port: UInt16
    private let mediaBridge = MediaBridge()
    public private(set) var remoteAccessEnabled = true

    private let eventContinuation: AsyncStream<AgentEvent>.Continuation
    public nonisolated let events: AsyncStream<AgentEvent>

    public init(_ deps: Dependencies) {
        self.deps = deps
        port = deps.config.port
        sender = EnvelopeSender(identity: deps.identity, now: deps.now)
        let trust = deps.trust
        receiver = EnvelopeReceiver(selfDeviceId: deps.identity.deviceId, resolveKey: { trust.publicKey(for: $0) }, now: deps.now)
        var continuation: AsyncStream<AgentEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        eventContinuation = continuation
        mediaBridge.coordinator = self
    }

    public nonisolated var deviceId: String { deps.identity.deviceId }
    public var trustedDevices: [TrustedDevice] { deps.trust.all }
    public var hasActiveSession: Bool { session != nil }

    public func setPort(_ port: UInt16) {
        self.port = port
        emit(.listening(port: port, addresses: NetworkInterfaces.lanAddresses(port: port)))
    }

    private func emit(_ event: AgentEvent) { eventContinuation.yield(event) }
    private func now() -> Int64 { deps.now() }

    // MARK: Inbound signaling

    public func handleText(_ text: String, from connection: ConnectionID) async {
        let data = Data(text.utf8)
        let result = receiver.receive(data)
        switch result {
        case .rejected(let reason, let detail):
            let peek = try? JSONDecoder().decode(Envelope.self, from: data)
            Log.session.notice("rejected \(peek?.type ?? "?", privacy: .public) from \(peek?.from.prefix(12) ?? "?", privacy: .public): \(reason.rawValue, privacy: .public) \(detail ?? "", privacy: .public)")
            if reason == .unknownSender, let peek, peek.type == SignalingType.sessionRequest.rawValue, DeviceID.isValid(peek.from) {
                rateLimitedReject(deviceId: peek.from, connection: connection)
            }
            if reason == .badSignature || reason == .tooLarge {
                deps.transport.close(connection)
            }
        case .accepted(let env, let payload, let senderKey):
            connections[connection] = env.from
            deviceConnections[env.from] = connection
            switch payload {
            case .pairRequest(let p): await handlePairRequest(env, p, senderKey: senderKey, connection: connection)
            case .sessionRequest(let p): await handleSessionRequest(env, p, connection: connection)
            case .sessionAuth(let p): await handleSessionAuth(env, p, connection: connection)
            case .sdpOffer(let p): await handleSdpOffer(env, p)
            case .iceCandidate(let p): handleIceCandidate(env, p)
            case .sessionResume: await handleSessionResume(env, connection: connection)
            case .sessionEnd(let p): await handleSessionEnd(env, p)
            case .pairResult, .sessionChallenge, .sessionAccept, .sessionReject, .sdpAnswer:
                Log.session.notice("ignoring controller-bound type \(env.type, privacy: .public)")
            }
        }
    }

    public func connectionOpened(_ connection: ConnectionID) {}

    public func connectionClosed(_ connection: ConnectionID) async {
        if let deviceId = connections.removeValue(forKey: connection), deviceConnections[deviceId] == connection {
            deviceConnections.removeValue(forKey: deviceId)
        }
        if let pending = pairing?.pending, pending.connection == connection {
            pairing?.pending = nil
            emit(.pairingFailed("controller disconnected before approval"))
        }
        if var s = session, s.connection == connection {
            s.signalingUp = false
            s.connection = nil
            session = s
            if s.state == .challenged {
                await tearDown(reason: .error, notify: false)
            } else {
                startResumeWindowIfNeeded()
            }
        }
    }

    // MARK: Pairing

    public func openPairing() -> QRPayload {
        let sessionId = Base64URL.encode(Pairing.randomSecret())
        let code = Pairing.randomSecret()
        let qr = QRPayload(
            hostDeviceId: deps.identity.deviceId,
            hostName: deps.config.hostName,
            addresses: NetworkInterfaces.lanAddresses(port: port),
            rendezvousUrl: deps.config.rendezvousURL,
            pairingSessionId: sessionId,
            pairingCode: code,
            now: now()
        )
        pairing = PairingState(sessionId: sessionId, code: code, qr: qr)
        receiver.acceptPairRequests = true
        schedule("pairing", afterMs: Pairing.ttlMs) { [weak self] in await self?.closePairing(reason: "expired") }
        emit(.pairingOpened(qr))
        return qr
    }

    public func cancelPairing() {
        closePairing(reason: "cancelled")
    }

    private func closePairing(reason: String?) {
        guard pairing != nil else { return }
        pairing = nil
        receiver.acceptPairRequests = false
        cancelTimer("pairing")
        if let reason { emit(.pairingFailed(reason)) }
        emit(.pairingClosed)
    }

    private func handlePairRequest(_ env: Envelope, _ p: PairRequestPayload, senderKey: Data, connection: ConnectionID) async {
        guard var state = pairing else {
            sendPairResult(to: env.from, connection: connection, approved: false, reason: .expired)
            return
        }
        guard now() < state.qr.expires_at else {
            sendPairResult(to: env.from, connection: connection, approved: false, reason: .expired)
            closePairing(reason: "expired")
            return
        }
        guard state.pending == nil else {
            sendPairResult(to: env.from, connection: connection, approved: false, reason: .busy)
            return
        }
        let proofOk = p.pairing_session_id == state.sessionId
            && Pairing.verifyProof(pairingCode: state.code, pairingSessionId: state.sessionId, controllerDeviceId: env.from, proof: p.proof)
        guard proofOk else {
            state.failures += 1
            pairing = state
            sendPairResult(to: env.from, connection: connection, approved: false, reason: .badProof)
            Log.session.notice("pairing proof failed (\(state.failures, privacy: .public))")
            if state.failures >= Pairing.maxFailedProofs { closePairing(reason: "too many failed proofs") }
            return
        }
        state.pending = PendingPairing(deviceId: env.from, publicKey: p.public_key, name: p.device_name, type: p.device_type, connection: connection)
        pairing = state
        let fingerprint = (try? DeviceID.fingerprint(deviceId: env.from)) ?? env.from
        emit(.pairingRequest(deviceId: env.from, deviceName: p.device_name, deviceType: p.device_type, fingerprint: fingerprint))
    }

    /// The user's decision from the host UI or CLI, after comparing fingerprints.
    public func resolvePairing(approved: Bool) async {
        guard let state = pairing, let pending = state.pending else { return }
        if approved {
            let device = TrustedDevice(deviceId: pending.deviceId, publicKey: pending.publicKey, name: pending.name, type: pending.type, pairedAt: now(), lastSeen: nil)
            do {
                try deps.trust.add(device)
            } catch {
                emit(.pairingFailed("could not save trusted device: \(error.localizedDescription)"))
                sendPairResult(to: pending.deviceId, connection: pending.connection, approved: false, reason: .denied)
                closePairing(reason: nil)
                return
            }
            sendPairResult(to: pending.deviceId, connection: pending.connection, approved: true, reason: nil)
            emit(.pairingCompleted(deviceId: pending.deviceId, deviceName: pending.name))
            closePairing(reason: nil)
        } else {
            sendPairResult(to: pending.deviceId, connection: pending.connection, approved: false, reason: .denied)
            closePairing(reason: "denied by user")
        }
    }

    private func sendPairResult(to deviceId: String, connection: ConnectionID, approved: Bool, reason: PairRejectReason?) {
        let payload = PairResultPayload(approved: approved, reason: reason, host_public_key: deps.identity.publicKeyB64, host_name: deps.config.hostName, rendezvous_url: deps.config.rendezvousURL)
        send(.pairResult(payload), to: deviceId, session: "", via: connection)
        forgetAttempt(deviceId)
    }

    // MARK: Session establishment

    private func handleSessionRequest(_ env: Envelope, _ p: SessionRequestPayload, connection: ConnectionID) async {
        guard remoteAccessEnabled else { reject(env.from, .remoteAccessDisabled, connection: connection); return }
        guard let device = deps.trust.device(env.from) else { reject(env.from, .untrusted, connection: connection); return }
        guard p.versions.contains(where: { Envelope.supportedVersions.contains($0) }) else {
            reject(env.from, .versionUnsupported, connection: connection); return
        }
        if let existing = session {
            if existing.deviceId == env.from {
                await tearDown(reason: .replaced, notify: false)
            } else if existing.mediaUp || existing.signalingUp {
                reject(env.from, .busy, connection: connection); return
            } else {
                await tearDown(reason: .error, notify: false)
            }
        }

        let sessionId = Base64URL.encode(Pairing.randomSecret())
        let hostNonce = Base64URL.encode(Pairing.randomSecret())
        let t = now()
        session = HostSession(
            id: sessionId, deviceId: env.from, deviceName: device.name, clientNonce: p.client_nonce, hostNonce: hostNonce,
            expiresAt: t + Int64(Limits.sessionLifetimeHours) * 3_600_000, path: p.path, state: .challenged, connection: connection,
            lastActivity: t, lastInput: t, media: nil, display: MediaDisplay.main(), malformedWindowStart: t
        )
        let challenge = SessionChallengePayload(host_nonce: hostNonce, client_nonce: p.client_nonce, session_id: sessionId, version: Envelope.protocolVersion, expires_at: session!.expiresAt)
        send(.sessionChallenge(challenge), to: env.from, session: sessionId, via: connection)
        forgetAttempt(env.from)
        emit(.sessionRequested(deviceId: env.from, deviceName: device.name))
        schedule("challenge", afterMs: Int64(Limits.challengeTimeoutSeconds) * 1000) { [weak self] in
            await self?.challengeTimedOut(sessionId: sessionId)
        }
    }

    private func challengeTimedOut(sessionId: String) async {
        guard let s = session, s.id == sessionId, s.state == .challenged else { return }
        Log.session.notice("challenge timed out")
        await tearDown(reason: .error, notify: false)
    }

    private func handleSessionAuth(_ env: Envelope, _ p: SessionAuthPayload, connection: ConnectionID) async {
        guard var s = session, s.state == .challenged, env.session == s.id, env.from == s.deviceId,
              p.client_nonce == s.clientNonce, p.host_nonce == s.hostNonce
        else {
            Log.session.notice("SESSION_AUTH did not match the outstanding challenge")
            reject(env.from, .authFailed, connection: connection, session: env.session)
            if let s = session, s.deviceId == env.from { await tearDown(reason: .error, notify: false) }
            return
        }
        cancelTimer("challenge")
        s.state = .authenticated
        s.connection = connection
        s.lastActivity = now()
        deps.trust.touch(env.from, at: now())

        if let factory = deps.mediaFactory {
            do {
                let media = try factory()
                media.delegate = mediaBridge
                media.setPath(s.path)
                s.display = try await media.start()
                s.media = media
            } catch {
                Log.media.error("media start failed: \(String(describing: error), privacy: .public)")
                emit(.warning("Media could not start: \(error). Is Screen Recording granted?"))
                session = nil
                reject(env.from, .hostError, connection: connection, session: env.session)
                return
            }
        }
        session = s
        deps.input?.configure(display: s.display)
        deps.power?.acquire()

        let accept = SessionAcceptPayload(client_nonce: s.clientNonce, host_nonce: s.hostNonce, display: s.display.info, resume_window_s: Limits.resumeWindowSeconds)
        send(.sessionAccept(accept), to: s.deviceId, session: s.id, via: connection)
        emit(.sessionAuthenticated(deviceId: s.deviceId, deviceName: s.deviceName))
        scheduleHousekeeping()
    }

    private func handleSdpOffer(_ env: Envelope, _ p: SdpOfferPayload) async {
        guard let s = session, s.id == env.session, s.deviceId == env.from, s.state != .challenged else { return }
        touch()
        guard let media = s.media else {
            Log.session.notice("offer received but media is disabled")
            await tearDown(reason: .error, notify: true)
            return
        }
        do {
            let answer = try await media.answer(offer: p.sdp)
            send(.sdpAnswer(SdpAnswerPayload(sdp: answer)), to: s.deviceId, session: s.id, via: nil)
        } catch {
            Log.media.error("answer failed: \(String(describing: error), privacy: .public)")
            await tearDown(reason: .error, notify: true)
        }
    }

    private func handleIceCandidate(_ env: Envelope, _ p: IceCandidatePayload) {
        guard let s = session, s.id == env.session, s.deviceId == env.from, s.state != .challenged else { return }
        touch()
        s.media?.add(candidate: p)
    }

    private func handleSessionResume(_ env: Envelope, connection: ConnectionID) async {
        guard var s = session, s.id == env.session, s.deviceId == env.from, s.state != .challenged,
              now() < s.expiresAt, now() - s.lastActivity <= Int64(Limits.resumeWindowSeconds) * 1000,
              deps.trust.device(env.from) != nil
        else {
            reject(env.from, .expired, connection: connection, session: env.session)
            return
        }
        cancelTimer("resume")
        s.connection = connection
        s.signalingUp = true
        s.lastActivity = now()
        session = s
        let accept = SessionAcceptPayload(client_nonce: s.clientNonce, host_nonce: s.hostNonce, display: s.display.info, resume_window_s: Limits.resumeWindowSeconds)
        send(.sessionAccept(accept), to: s.deviceId, session: s.id, via: connection)
        emit(.info("session resumed by \(s.deviceName)"))
    }

    private func handleSessionEnd(_ env: Envelope, _ p: SessionEndPayload) async {
        guard let s = session, s.id == env.session, s.deviceId == env.from else { return }
        await tearDown(reason: p.reason, notify: false)
    }

    // MARK: Media callbacks (from MediaBridge)

    func mediaCandidate(_ candidate: IceCandidatePayload) {
        guard let s = session else { return }
        send(.iceCandidate(candidate), to: s.deviceId, session: s.id, via: nil)
    }

    func mediaState(_ state: MediaConnectionState) async {
        guard var s = session else { return }
        switch state {
        case .connected(let path):
            s.mediaUp = true
            s.state = .connected
            s.lastActivity = now()
            session = s
            cancelTimer("resume")
            emit(.sessionConnected(deviceName: s.deviceName, path: path))
        case .disconnected, .failed:
            s.mediaUp = false
            session = s
            deps.input?.releaseAll()
            startResumeWindowIfNeeded()
        case .closed:
            s.mediaUp = false
            session = s
        case .connecting:
            break
        }
    }

    func mediaChannelOpened(_ label: ChannelLabel) {
        guard let s = session, label == .control else { return }
        s.media?.send(.displayInfo(s.display.info), ts: 0)
    }

    func mediaFrame(_ frame: DataChannelFrame, on label: ChannelLabel) async {
        guard var s = session else { return }
        let t = now()
        s.lastActivity = t
        switch frame.message {
        case .hello(let versions, _, _):
            session = s
            if !versions.contains(where: { Envelope.supportedVersions.contains($0) }) {
                await tearDown(reason: .error, notify: true)
            }
        case .ping(let nonce):
            session = s
            s.media?.send(.pong(nonce: nonce), ts: t)
        case .pong, .displayInfo:
            session = s
        case .streamSettings:
            session = s
        case .bye(let reason):
            await tearDown(reason: reason, notify: false)
        case .mouseMove, .mouseMoveRel, .mouseDown, .mouseUp, .scroll, .keyDown, .keyUp, .text:
            s.lastInput = t
            session = s
            if deps.config.inputEnabled { deps.input?.inject(frame.message, now: t) }
        }
    }

    func mediaRejected(_ error: DataChannelError) async {
        guard var s = session else { return }
        let t = now()
        if t - s.malformedWindowStart >= 60_000 { s.malformedWindowStart = t; s.malformedCount = 0 }
        s.malformedCount += 1
        session = s
        if s.malformedCount >= Limits.malformedPerMinuteBeforeDisconnect {
            Log.session.error("too many malformed data channel messages")
            await tearDown(reason: .error, notify: true)
        }
    }

    // MARK: Session lifecycle

    private func touch() {
        session?.lastActivity = now()
    }

    private func startResumeWindowIfNeeded() {
        guard let s = session, !s.mediaUp, !s.signalingUp else { return }
        schedule("resume", afterMs: Int64(Limits.resumeWindowSeconds) * 1000) { [weak self] in
            guard let self, let s = await self.session, !s.mediaUp, !s.signalingUp else { return }
            await self.tearDown(reason: .error, notify: false)
        }
    }

    private func scheduleHousekeeping() {
        schedule("housekeeping", afterMs: 60_000) { [weak self] in await self?.housekeeping() }
    }

    private func housekeeping() async {
        guard let s = session else { return }
        let t = now()
        if t >= s.expiresAt {
            await tearDown(reason: .expired, notify: true)
            return
        }
        if t - s.lastInput >= Int64(deps.config.idleTimeout * 1000) {
            await tearDown(reason: .idleTimeout, notify: true)
            return
        }
        scheduleHousekeeping()
    }

    public func endSession(reason: SessionEndReason = .user) async {
        await tearDown(reason: reason, notify: true)
    }

    private func tearDown(reason: SessionEndReason, notify: Bool) async {
        guard let s = session else { return }
        session = nil
        for key in ["challenge", "resume", "housekeeping"] { cancelTimer(key) }
        if notify {
            s.media?.send(.bye(reason), ts: now())
            send(.sessionEnd(SessionEndPayload(reason: reason)), to: s.deviceId, session: s.id, via: nil)
        }
        deps.input?.releaseAll()
        await s.media?.stop()
        deps.power?.release()
        receiver.forgetSession(from: s.deviceId, session: s.id)
        sender.forgetSession(to: s.deviceId, session: s.id)
        sender.forgetSession(to: s.deviceId, session: "")
        receiver.forgetSession(from: s.deviceId, session: "")
        emit(.sessionEnded(reason))
    }

    // MARK: Trust and kill switch

    public func revoke(deviceId: String) async {
        guard (try? deps.trust.revoke(deviceId)) == true else { return }
        receiver.forgetSender(deviceId)
        if let s = session, s.deviceId == deviceId {
            await tearDown(reason: .revoked, notify: true)
        }
        if let connection = deviceConnections[deviceId] { deps.transport.close(connection) }
        emit(.deviceRevoked(deviceId: deviceId))
    }

    public func setRemoteAccess(_ enabled: Bool) async {
        guard enabled != remoteAccessEnabled else { return }
        remoteAccessEnabled = enabled
        if !enabled {
            closePairing(reason: "remote access disabled")
            await tearDown(reason: .remoteAccessDisabled, notify: true)
        }
        emit(.remoteAccessChanged(enabled))
    }

    public func shutdown() async {
        closePairing(reason: nil)
        await tearDown(reason: .error, notify: true)
        for key in timers.keys { cancelTimer(key) }
    }

    // MARK: Helpers

    private func reject(_ deviceId: String, _ reason: SessionRejectReason, connection: ConnectionID, session: String = "") {
        send(.sessionReject(SessionRejectPayload(reason: reason)), to: deviceId, session: session, via: connection)
        if session.isEmpty { forgetAttempt(deviceId) }
        emit(.rejected(deviceId: deviceId, reason: reason))
    }

    /// A pairing attempt or a session attempt is one exchange in the empty session namespace.
    /// Both sides reset their `seq` state for it once the reply is sent (spec section 6).
    private func forgetAttempt(_ deviceId: String) {
        receiver.forgetSession(from: deviceId, session: "")
        sender.forgetSession(to: deviceId, session: "")
    }

    /// One signed rejection per unknown device per minute. Strangers get no other state (spec section 8.3).
    private func rateLimitedReject(deviceId: String, connection: ConnectionID) {
        let t = now()
        if let last = lastRejectAt[deviceId], t - last < 60_000 { return }
        lastRejectAt[deviceId] = t
        reject(deviceId, .untrusted, connection: connection)
    }

    private func send(_ payload: SignalingPayload, to deviceId: String, session: String, via connection: ConnectionID?) {
        guard let target = connection ?? deviceConnections[deviceId] else {
            Log.session.notice("no connection for \(deviceId.prefix(12), privacy: .public); dropping \(payload.type.rawValue, privacy: .public)")
            return
        }
        do {
            let env = try sender.build(payload, to: deviceId, session: session)
            deps.transport.send(String(decoding: try env.serialized(), as: UTF8.self), to: target)
        } catch {
            Log.session.error("failed to build \(payload.type.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func schedule(_ key: String, afterMs: Int64, _ action: @escaping @Sendable () async -> Void) {
        cancelTimer(key)
        timers[key] = Task { [afterMs] in
            try? await Task.sleep(nanoseconds: UInt64(max(afterMs, 0)) * 1_000_000)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    private func cancelTimer(_ key: String) {
        timers.removeValue(forKey: key)?.cancel()
    }
}

/// Hops media callbacks from WebRTC threads into the actor, preserving their order.
final class MediaBridge: MediaSessionDelegate, @unchecked Sendable {
    weak var coordinator: SessionCoordinator?
    private let queue = OrderedExecutor()

    func media(didGenerateCandidate candidate: IceCandidatePayload) {
        queue.enqueue { [weak self] in await self?.coordinator?.mediaCandidate(candidate) }
    }
    func media(didChangeState state: MediaConnectionState) {
        queue.enqueue { [weak self] in await self?.coordinator?.mediaState(state) }
    }
    func media(didOpenChannel label: ChannelLabel) {
        queue.enqueue { [weak self] in await self?.coordinator?.mediaChannelOpened(label) }
    }
    func media(didReceive frame: DataChannelFrame, on label: ChannelLabel) {
        queue.enqueue { [weak self] in await self?.coordinator?.mediaFrame(frame, on: label) }
    }
    func media(didRejectMessage error: DataChannelError) {
        queue.enqueue { [weak self] in await self?.coordinator?.mediaRejected(error) }
    }
}
