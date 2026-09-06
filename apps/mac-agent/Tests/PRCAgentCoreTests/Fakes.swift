import Foundation
import PRCIdentity
import PRCProtocol
@testable import PRCAgentCore

/// Records what the coordinator sends, per connection.
final class InMemoryTransport: SignalingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var outbox: [ConnectionID: [Envelope]] = [:]
    private(set) var closed: [ConnectionID] = []

    func send(_ text: String, to id: ConnectionID) {
        let env = try! JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
        lock.lock(); outbox[id, default: []].append(env); lock.unlock()
    }

    func close(_ id: ConnectionID) {
        lock.lock(); closed.append(id); lock.unlock()
    }

    func drain(_ id: ConnectionID) -> [Envelope] {
        lock.lock(); defer { lock.unlock() }
        return outbox.removeValue(forKey: id) ?? []
    }
}

final class FakeMediaSession: MediaSession, @unchecked Sendable {
    weak var delegate: MediaSessionDelegate?
    let lock = NSLock()
    var started = false
    var stopped = false
    var offers: [String] = []
    var candidates: [IceCandidatePayload] = []
    var sent: [DataChannelMessage] = []
    var failStart = false

    static let display = MediaDisplay(displayID: 7, pointBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2, pixelSize: CGSize(width: 3840, height: 2160), captureSize: CGSize(width: 1920, height: 1080))

    func start() async throws -> MediaDisplay {
        if failStart { throw MediaError.screenRecordingDenied }
        lock.withLock { started = true }
        return FakeMediaSession.display
    }
    func answer(offer: String) async throws -> String {
        lock.withLock { offers.append(offer) }
        return "v=0\r\nanswer-for-\(offer.count)\r\n"
    }
    func add(candidate: IceCandidatePayload) { lock.lock(); candidates.append(candidate); lock.unlock() }
    func send(_ message: DataChannelMessage, ts: Int64) { lock.lock(); sent.append(message); lock.unlock() }
    func stop() async { lock.withLock { stopped = true } }
}

final class RecordingInput: InputSink, @unchecked Sendable {
    let lock = NSLock()
    var injected: [DataChannelMessage] = []
    var displays: [MediaDisplay] = []
    var released = 0
    func configure(display: MediaDisplay) { lock.lock(); displays.append(display); lock.unlock() }
    func inject(_ message: DataChannelMessage, now: Int64) -> Bool { lock.lock(); injected.append(message); lock.unlock(); return true }
    func releaseAll() { lock.lock(); released += 1; lock.unlock() }
}

/// A controller as the tests see it: an identity, a sender, and a receiver that trusts the host.
final class TestController {
    let identity = SoftwareIdentity()
    var sender: EnvelopeSender
    var receiver: EnvelopeReceiver
    let connection = ConnectionID()
    var deviceId: String { identity.deviceId }

    init(hostPublicKey: Data, now: @escaping @Sendable () -> Int64) {
        sender = EnvelopeSender(identity: identity, now: now)
        receiver = EnvelopeReceiver(selfDeviceId: identity.deviceId, resolveKey: { _ in hostPublicKey }, now: now)
    }

    func text(_ payload: SignalingPayload, to host: String, session: String) throws -> String {
        String(decoding: try sender.build(payload, to: host, session: session).serialized(), as: UTF8.self)
    }

    /// Verifies every host message with the host key and returns the typed payloads.
    func accept(_ envelopes: [Envelope]) throws -> [(Envelope, SignalingPayload)] {
        try envelopes.map { env in
            switch receiver.receive(try env.serialized()) {
            case .accepted(let e, let p, _):
                // A reply in the empty namespace ends a pairing or session attempt; reset like a real controller.
                if e.session.isEmpty { receiver.forgetSession(from: e.from, session: "") }
                return (e, p)
            case .rejected(let r, let d): throw TestError.rejected("\(r.rawValue) \(d ?? "") for \(env.type)")
            }
        }
    }
}

enum TestError: Error { case rejected(String); case timeout(String) }

struct Clock: Sendable {
    let value: LockedValue<Int64>
    init(_ start: Int64 = 1_757_203_200_000) { value = LockedValue(start) }
    var now: @Sendable () -> Int64 { let v = value; return { v.get() } }
    func advance(ms: Int64) { value.set(value.get() + ms) }
}

final class LockedValue<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("prc-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func waitUntil(timeoutMs: Int = 5000, _ label: String, _ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw TestError.timeout(label)
}

/// A host with fakes wired in, ready for a flow test.
struct Harness {
    let clock = Clock()
    let hostIdentity = SoftwareIdentity()
    let transport = InMemoryTransport()
    let media = LockedValue<FakeMediaSession?>(nil)
    let input = RecordingInput()
    let trust: TrustStore
    let coordinator: SessionCoordinator
    let controller: TestController
    var eventsTask: Task<Void, Never>!
    let events = LockedValue<[AgentEvent]>([])

    init(mediaEnabled: Bool = true, failMediaStart: Bool = false) {
        trust = try! TrustStore(directory: tempDirectory())
        let config = AgentConfig(hostName: "Test Mini", port: 0, advertiseBonjour: false, dataDirectory: tempDirectory(), mediaEnabled: mediaEnabled)
        let mediaBox = media
        let factory: MediaSessionFactory? = mediaEnabled ? {
            let m = FakeMediaSession()
            m.failStart = failMediaStart
            mediaBox.set(m)
            return m
        } : nil
        coordinator = SessionCoordinator(.init(identity: hostIdentity, trust: trust, config: config, transport: transport, mediaFactory: factory, input: input, power: nil, now: clock.now))
        controller = TestController(hostPublicKey: hostIdentity.publicKeyRaw, now: clock.now)
        let sink = events
        let stream = coordinator.events
        eventsTask = Task { for await e in stream { sink.set(sink.get() + [e]) } }
    }

    var hostId: String { hostIdentity.deviceId }

    func trustController(_ c: TestController? = nil) {
        let c = c ?? controller
        try! trust.add(TrustedDevice(deviceId: c.deviceId, publicKey: c.identity.publicKeyB64, name: "Test Controller", type: .web, pairedAt: clock.now(), lastSeen: nil))
    }

    func send(_ payload: SignalingPayload, session: String = "", from c: TestController? = nil) async throws -> [(Envelope, SignalingPayload)] {
        let c = c ?? controller
        await coordinator.handleText(try c.text(payload, to: hostId, session: session), from: c.connection)
        return try c.accept(transport.drain(c.connection))
    }

    static let request = SignalingPayload.sessionRequest(SessionRequestPayload(client_nonce: "AAECAwQFBgcICQoLDA0ODw", versions: [1], path: .lan, capabilities: SessionCapabilities(codecs: [.h264], max_height: 1080, max_fps: 60)))

    /// Runs REQUEST, CHALLENGE, AUTH, ACCEPT and returns the session id and accept payload.
    func authenticate() async throws -> (String, SessionAcceptPayload) {
        let replies = try await send(Harness.request)
        guard replies.count == 1, case .sessionChallenge(let challenge) = replies[0].1 else { throw TestError.rejected("expected challenge, got \(replies.map { $0.0.type })") }
        let auth = SignalingPayload.sessionAuth(SessionAuthPayload(client_nonce: challenge.client_nonce, host_nonce: challenge.host_nonce))
        let accepted = try await send(auth, session: challenge.session_id)
        guard accepted.count == 1, case .sessionAccept(let accept) = accepted[0].1 else { throw TestError.rejected("expected accept, got \(accepted.map { $0.0.type })") }
        return (challenge.session_id, accept)
    }
}
