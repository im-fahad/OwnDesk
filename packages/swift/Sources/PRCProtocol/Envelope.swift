import CryptoKit
import Foundation
import PRCIdentity

/// Signaling envelope (spec section 6).
public struct Envelope: Codable, Sendable, Equatable {
    public var v: Int
    public var type: String
    public var from: String
    public var to: String
    public var session: String
    public var seq: Int
    public var ts: Int64
    public var payload: String
    public var sig: String

    public static let context = "prc-signaling-v1"
    public static let protocolVersion = 1
    public static let supportedVersions: [Int] = [1]
    public static let maxBytes = 65536
    public static let maxClockSkewMs: Int64 = 300_000

    public init(v: Int = Envelope.protocolVersion, type: String, from: String, to: String, session: String, seq: Int, ts: Int64, payload: String, sig: String) {
        self.v = v; self.type = type; self.from = from; self.to = to; self.session = session
        self.seq = seq; self.ts = ts; self.payload = payload; self.sig = sig
    }

    /// The bytes covered by the signature: context label and the eight fields joined by newline.
    public static func signingInput(v: Int, type: String, from: String, to: String, session: String, seq: Int, ts: Int64, payload: String) -> Data {
        Data([context, String(v), type, from, to, session, String(seq), String(ts), payload].joined(separator: "\n").utf8)
    }

    public func signingInput() -> Data {
        Envelope.signingInput(v: v, type: type, from: from, to: to, session: session, seq: seq, ts: ts, payload: payload)
    }

    public static func signed(v: Int = Envelope.protocolVersion, type: String, from: String, to: String, session: String, seq: Int, ts: Int64, payload: String, identity: any SigningIdentity) throws -> Envelope {
        let sig = try identity.sign(signingInput(v: v, type: type, from: from, to: to, session: session, seq: seq, ts: ts, payload: payload))
        return Envelope(v: v, type: type, from: from, to: to, session: session, seq: seq, ts: ts, payload: payload, sig: Base64URL.encode(sig))
    }

    public func verifySignature(publicKeyRaw: Data) -> Bool {
        guard let sig = Base64URL.decode(sig) else { return false }
        return Verifier.verify(publicKeyRaw: publicKeyRaw, data: signingInput(), signature: sig)
    }

    public static func encodePayload(json: Data) -> String { Base64URL.encode(json) }

    public func payloadData() -> Data? { Base64URL.decode(payload) }

    /// Returns the name of the first field that violates envelope.json, or nil when the shape is valid.
    public func shapeProblem() -> String? {
        if !(1...1000).contains(v) { return "v" }
        if type.isEmpty || type.count > 32 || !type.utf8.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || $0 == 0x5F }) { return "type" }
        if !DeviceID.isValid(from) { return "from" }
        if !DeviceID.isValid(to) { return "to" }
        if !(session.isEmpty || Wire.isBytes16(session)) { return "session" }
        if seq < 1 { return "seq" }
        if ts < 0 { return "ts" }
        if !Base64URL.isValid(payload) { return "payload" }
        if !Wire.isSignature(sig) { return "sig" }
        return nil
    }

    public func serialized() throws -> Data { try JSONEncoder().encode(self) }
}

/// Builds and signs outgoing envelopes, numbering `seq` per (recipient, session).
public struct EnvelopeSender: Sendable {
    private let identity: any SigningIdentity
    private let now: @Sendable () -> Int64
    private var seq: [String: Int] = [:]

    public init(identity: any SigningIdentity, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.identity = identity
        self.now = now
    }

    public var deviceId: String { identity.deviceId }

    public mutating func build(type: SignalingType, to: String, session: String, payloadJSON: Data) throws -> Envelope {
        let key = "\(to)|\(session)"
        let next = (seq[key] ?? 0) + 1
        seq[key] = next
        return try Envelope.signed(type: type.rawValue, from: identity.deviceId, to: to, session: session, seq: next, ts: now(), payload: Envelope.encodePayload(json: payloadJSON), identity: identity)
    }

    public mutating func build(_ payload: SignalingPayload, to: String, session: String) throws -> Envelope {
        try build(type: payload.type, to: to, session: session, payloadJSON: payload.encoded())
    }

    public mutating func forgetSession(to: String, session: String) {
        seq.removeValue(forKey: "\(to)|\(session)")
    }
}
