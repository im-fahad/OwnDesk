import Foundation
import PRCIdentity

public enum ReceiveRejection: String, Sendable {
    case tooLarge = "too_large"
    case malformed
    case unsupportedVersion = "unsupported_version"
    case wrongRecipient = "wrong_recipient"
    case unknownType = "unknown_type"
    case unknownSender = "unknown_sender"
    case badSignature = "bad_signature"
    case staleTimestamp = "stale_timestamp"
    case replayed
    case invalidPayload = "invalid_payload"
}

public enum ReceiveResult: Sendable {
    case accepted(envelope: Envelope, payload: SignalingPayload, senderPublicKey: Data)
    case rejected(ReceiveRejection, detail: String?)

    /// "ok" or the rejection reason string. Matches the TypeScript reference and the vectors.
    public var reasonString: String {
        switch self {
        case .accepted: "ok"
        case .rejected(let r, _): r.rawValue
        }
    }
}

/// Receiver rules for signaling envelopes (spec section 6), in the same order as the TypeScript reference.
public struct EnvelopeReceiver: Sendable {
    public typealias KeyResolver = @Sendable (_ deviceId: String) -> Data?

    public var acceptPairRequests: Bool
    private let selfDeviceId: String
    private let resolveKey: KeyResolver
    private let now: @Sendable () -> Int64
    private let maxSkewMs: Int64
    private let supportedVersions: Set<Int>
    private var lastSeq: [String: Int] = [:]

    public init(
        selfDeviceId: String,
        resolveKey: @escaping KeyResolver,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        maxSkewMs: Int64 = Envelope.maxClockSkewMs,
        acceptPairRequests: Bool = false,
        supportedVersions: Set<Int> = Set(Envelope.supportedVersions)
    ) {
        self.selfDeviceId = selfDeviceId
        self.resolveKey = resolveKey
        self.now = now
        self.maxSkewMs = maxSkewMs
        self.acceptPairRequests = acceptPairRequests
        self.supportedVersions = supportedVersions
    }

    public mutating func receive(_ raw: Data) -> ReceiveResult {
        if raw.count > Envelope.maxBytes { return .rejected(.tooLarge, detail: nil) }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: raw) else { return .rejected(.malformed, detail: "not an envelope") }
        if let field = env.shapeProblem() { return .rejected(.malformed, detail: field) }
        guard supportedVersions.contains(env.v) else { return .rejected(.unsupportedVersion, detail: nil) }
        guard env.to == selfDeviceId else { return .rejected(.wrongRecipient, detail: nil) }
        guard let type = SignalingType(rawValue: env.type) else { return .rejected(.unknownType, detail: nil) }

        let senderKey: Data
        var payload: SignalingPayload?
        if type == .pairRequest {
            guard acceptPairRequests else { return .rejected(.unknownSender, detail: "pairing not open") }
            guard let data = env.payloadData(), let decoded = try? SignalingPayload.decode(type: .pairRequest, from: data),
                  case .pairRequest(let request) = decoded
            else { return .rejected(.invalidPayload, detail: nil) }
            guard let pk = Base64URL.decode(request.public_key), let derived = try? DeviceID.deviceId(publicKeyRaw: pk) else {
                return .rejected(.invalidPayload, detail: "public_key")
            }
            guard derived == env.from else { return .rejected(.unknownSender, detail: "public_key does not match from") }
            senderKey = pk
            payload = decoded
        } else {
            guard let key = resolveKey(env.from) else { return .rejected(.unknownSender, detail: nil) }
            senderKey = key
        }

        guard env.verifySignature(publicKeyRaw: senderKey) else { return .rejected(.badSignature, detail: nil) }
        guard abs(now() - env.ts) <= maxSkewMs else { return .rejected(.staleTimestamp, detail: nil) }

        let key = "\(env.from)|\(env.session)"
        guard env.seq > (lastSeq[key] ?? 0) else { return .rejected(.replayed, detail: nil) }

        if payload == nil {
            guard let data = env.payloadData() else { return .rejected(.invalidPayload, detail: nil) }
            do { payload = try SignalingPayload.decode(type: type, from: data) } catch { return .rejected(.invalidPayload, detail: "\(error)") }
        }

        // Record seq only for fully accepted messages. Replaying a rejected message gains nothing.
        lastSeq[key] = env.seq
        return .accepted(envelope: env, payload: payload!, senderPublicKey: senderKey)
    }

    public mutating func forgetSession(from: String, session: String) {
        lastSeq.removeValue(forKey: "\(from)|\(session)")
    }

    public mutating func forgetSender(_ from: String) {
        for key in lastSeq.keys where key.hasPrefix("\(from)|") { lastSeq.removeValue(forKey: key) }
    }
}
