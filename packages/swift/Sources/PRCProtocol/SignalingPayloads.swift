import Foundation
import PRCIdentity

// Wire field names are snake_case on purpose so the Swift property is the JSON key.
// Validation mirrors packages/protocol/schemas/signaling/*.json.

public protocol WirePayload: Codable, Sendable, Equatable {
    func validate() throws
}

public enum DeviceType: String, Codable, Sendable { case mac, android, web }
public enum ConnectionPath: String, Codable, Sendable { case lan, cloud }
public enum Codec: String, Codable, Sendable { case h264 = "H264" }

public enum PairRejectReason: String, Codable, Sendable {
    case denied, expired, busy
    case badProof = "bad_proof"
}

public enum SessionRejectReason: String, Codable, Sendable {
    case untrusted, revoked, busy, expired, malformed
    case remoteAccessDisabled = "remote_access_disabled"
    case authFailed = "auth_failed"
    case versionUnsupported = "version_unsupported"
}

public enum SessionEndReason: String, Codable, Sendable {
    case user, revoked, replaced, error
    case idleTimeout = "idle_timeout"
    case remoteAccessDisabled = "remote_access_disabled"
}

public struct DisplayInfo: WirePayload {
    public var display_id: String
    public var width_px: Int
    public var height_px: Int
    public var scale: Double

    public init(display_id: String, width_px: Int, height_px: Int, scale: Double) {
        self.display_id = display_id; self.width_px = width_px; self.height_px = height_px; self.scale = scale
    }

    public func validate() throws {
        try Wire.require((1...64).contains(display_id.count), "display_id")
        try Wire.require((1...16384).contains(width_px), "width_px")
        try Wire.require((1...16384).contains(height_px), "height_px")
        try Wire.require((0.5...4).contains(scale), "scale")
    }
}

public struct PairRequestPayload: WirePayload {
    public var public_key: String
    public var device_name: String
    public var device_type: DeviceType
    public var pairing_session_id: String
    public var proof: String

    public init(public_key: String, device_name: String, device_type: DeviceType, pairing_session_id: String, proof: String) {
        self.public_key = public_key; self.device_name = device_name; self.device_type = device_type
        self.pairing_session_id = pairing_session_id; self.proof = proof
    }

    public func validate() throws {
        try Wire.require(Wire.isPublicKey(public_key), "public_key")
        try Wire.require(Wire.isDeviceName(device_name), "device_name")
        try Wire.require(Wire.isBytes16(pairing_session_id), "pairing_session_id")
        try Wire.require(Wire.isBytes32(proof), "proof")
    }
}

public struct PairResultPayload: WirePayload {
    public var approved: Bool
    public var reason: PairRejectReason?
    public var host_public_key: String
    public var host_name: String
    public var rendezvous_url: String?

    enum CodingKeys: String, CodingKey { case approved, reason, host_public_key, host_name, rendezvous_url }

    public init(approved: Bool, reason: PairRejectReason?, host_public_key: String, host_name: String, rendezvous_url: String?) {
        self.approved = approved; self.reason = reason; self.host_public_key = host_public_key
        self.host_name = host_name; self.rendezvous_url = rendezvous_url
    }

    // Nullable fields must be present on the wire. Swift's synthesized Codable would omit nil, so encode null explicitly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.reason), c.contains(.rendezvous_url) else { throw PayloadError.invalid("reason and rendezvous_url are required") }
        approved = try c.decode(Bool.self, forKey: .approved)
        reason = try c.decodeIfPresent(PairRejectReason.self, forKey: .reason)
        host_public_key = try c.decode(String.self, forKey: .host_public_key)
        host_name = try c.decode(String.self, forKey: .host_name)
        rendezvous_url = try c.decodeIfPresent(String.self, forKey: .rendezvous_url)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(approved, forKey: .approved)
        if let reason { try c.encode(reason, forKey: .reason) } else { try c.encodeNil(forKey: .reason) }
        try c.encode(host_public_key, forKey: .host_public_key)
        try c.encode(host_name, forKey: .host_name)
        if let rendezvous_url { try c.encode(rendezvous_url, forKey: .rendezvous_url) } else { try c.encodeNil(forKey: .rendezvous_url) }
    }

    public func validate() throws {
        try Wire.require(Wire.isPublicKey(host_public_key), "host_public_key")
        try Wire.require(Wire.isDeviceName(host_name), "host_name")
        if let rendezvous_url { try Wire.require(Wire.isWsUrl(rendezvous_url), "rendezvous_url") }
    }
}

public struct SessionCapabilities: WirePayload {
    public var codecs: [Codec]
    public var max_height: Int
    public var max_fps: Int

    public init(codecs: [Codec], max_height: Int, max_fps: Int) {
        self.codecs = codecs; self.max_height = max_height; self.max_fps = max_fps
    }

    public func validate() throws {
        try Wire.require((1...8).contains(codecs.count), "codecs")
        try Wire.require((360...4320).contains(max_height), "max_height")
        try Wire.require((5...120).contains(max_fps), "max_fps")
    }
}

public struct SessionRequestPayload: WirePayload {
    public var client_nonce: String
    public var versions: [Int]
    public var path: ConnectionPath
    public var capabilities: SessionCapabilities

    public init(client_nonce: String, versions: [Int], path: ConnectionPath, capabilities: SessionCapabilities) {
        self.client_nonce = client_nonce; self.versions = versions; self.path = path; self.capabilities = capabilities
    }

    public func validate() throws {
        try Wire.require(Wire.isBytes16(client_nonce), "client_nonce")
        try Wire.require((1...16).contains(versions.count) && versions.allSatisfy { (1...1000).contains($0) }, "versions")
        try capabilities.validate()
    }
}

public struct SessionChallengePayload: WirePayload {
    public var host_nonce: String
    public var client_nonce: String
    public var session_id: String
    public var version: Int
    public var expires_at: Int64

    public init(host_nonce: String, client_nonce: String, session_id: String, version: Int, expires_at: Int64) {
        self.host_nonce = host_nonce; self.client_nonce = client_nonce; self.session_id = session_id
        self.version = version; self.expires_at = expires_at
    }

    public func validate() throws {
        try Wire.require(Wire.isBytes16(host_nonce), "host_nonce")
        try Wire.require(Wire.isBytes16(client_nonce), "client_nonce")
        try Wire.require(Wire.isBytes16(session_id), "session_id")
        try Wire.require((1...1000).contains(version), "version")
        try Wire.require(expires_at >= 0, "expires_at")
    }
}

public struct SessionAuthPayload: WirePayload {
    public var client_nonce: String
    public var host_nonce: String

    public init(client_nonce: String, host_nonce: String) {
        self.client_nonce = client_nonce; self.host_nonce = host_nonce
    }

    public func validate() throws {
        try Wire.require(Wire.isBytes16(client_nonce), "client_nonce")
        try Wire.require(Wire.isBytes16(host_nonce), "host_nonce")
    }
}

public struct SessionAcceptPayload: WirePayload {
    public var client_nonce: String
    public var host_nonce: String
    public var display: DisplayInfo
    public var resume_window_s: Int

    public init(client_nonce: String, host_nonce: String, display: DisplayInfo, resume_window_s: Int) {
        self.client_nonce = client_nonce; self.host_nonce = host_nonce; self.display = display; self.resume_window_s = resume_window_s
    }

    public func validate() throws {
        try Wire.require(Wire.isBytes16(client_nonce), "client_nonce")
        try Wire.require(Wire.isBytes16(host_nonce), "host_nonce")
        try display.validate()
        try Wire.require((0...86400).contains(resume_window_s), "resume_window_s")
    }
}

public struct SessionRejectPayload: WirePayload {
    public var reason: SessionRejectReason
    public init(reason: SessionRejectReason) { self.reason = reason }
    public func validate() throws {}
}

public struct SdpOfferPayload: WirePayload {
    public var sdp: String
    public var ice_restart: Bool
    public init(sdp: String, ice_restart: Bool) { self.sdp = sdp; self.ice_restart = ice_restart }
    public func validate() throws { try Wire.require((1...32768).contains(sdp.count), "sdp") }
}

public struct SdpAnswerPayload: WirePayload {
    public var sdp: String
    public init(sdp: String) { self.sdp = sdp }
    public func validate() throws { try Wire.require((1...32768).contains(sdp.count), "sdp") }
}

public struct IceCandidatePayload: WirePayload {
    public var candidate: String
    public var sdp_mid: String?
    public var sdp_mline_index: Int?

    enum CodingKeys: String, CodingKey { case candidate, sdp_mid, sdp_mline_index }

    public init(candidate: String, sdp_mid: String?, sdp_mline_index: Int?) {
        self.candidate = candidate; self.sdp_mid = sdp_mid; self.sdp_mline_index = sdp_mline_index
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.sdp_mid), c.contains(.sdp_mline_index) else { throw PayloadError.invalid("sdp_mid and sdp_mline_index are required") }
        candidate = try c.decode(String.self, forKey: .candidate)
        sdp_mid = try c.decodeIfPresent(String.self, forKey: .sdp_mid)
        sdp_mline_index = try c.decodeIfPresent(Int.self, forKey: .sdp_mline_index)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(candidate, forKey: .candidate)
        if let sdp_mid { try c.encode(sdp_mid, forKey: .sdp_mid) } else { try c.encodeNil(forKey: .sdp_mid) }
        if let sdp_mline_index { try c.encode(sdp_mline_index, forKey: .sdp_mline_index) } else { try c.encodeNil(forKey: .sdp_mline_index) }
    }

    public func validate() throws {
        try Wire.require((1...1024).contains(candidate.count), "candidate")
        if let sdp_mid { try Wire.require(sdp_mid.count <= 64, "sdp_mid") }
        if let sdp_mline_index { try Wire.require((0...64).contains(sdp_mline_index), "sdp_mline_index") }
    }
}

public struct SessionResumePayload: WirePayload {
    // An empty struct's synthesized Codable accepts any JSON. Require a JSON object like the schema does.
    private enum CodingKeys: CodingKey {}
    public init() {}
    public init(from decoder: Decoder) throws { _ = try decoder.container(keyedBy: CodingKeys.self) }
    public func encode(to encoder: Encoder) throws { _ = encoder.container(keyedBy: CodingKeys.self) }
    public func validate() throws {}
}

public struct SessionEndPayload: WirePayload {
    public var reason: SessionEndReason
    public init(reason: SessionEndReason) { self.reason = reason }
    public func validate() throws {}
}

public enum SignalingType: String, CaseIterable, Sendable {
    case pairRequest = "PAIR_REQUEST"
    case pairResult = "PAIR_RESULT"
    case sessionRequest = "SESSION_REQUEST"
    case sessionChallenge = "SESSION_CHALLENGE"
    case sessionAuth = "SESSION_AUTH"
    case sessionAccept = "SESSION_ACCEPT"
    case sessionReject = "SESSION_REJECT"
    case sdpOffer = "SDP_OFFER"
    case sdpAnswer = "SDP_ANSWER"
    case iceCandidate = "ICE_CANDIDATE"
    case sessionResume = "SESSION_RESUME"
    case sessionEnd = "SESSION_END"
}

/// A decoded and validated signaling payload.
public enum SignalingPayload: Sendable, Equatable {
    case pairRequest(PairRequestPayload)
    case pairResult(PairResultPayload)
    case sessionRequest(SessionRequestPayload)
    case sessionChallenge(SessionChallengePayload)
    case sessionAuth(SessionAuthPayload)
    case sessionAccept(SessionAcceptPayload)
    case sessionReject(SessionRejectPayload)
    case sdpOffer(SdpOfferPayload)
    case sdpAnswer(SdpAnswerPayload)
    case iceCandidate(IceCandidatePayload)
    case sessionResume(SessionResumePayload)
    case sessionEnd(SessionEndPayload)

    public var type: SignalingType {
        switch self {
        case .pairRequest: .pairRequest
        case .pairResult: .pairResult
        case .sessionRequest: .sessionRequest
        case .sessionChallenge: .sessionChallenge
        case .sessionAuth: .sessionAuth
        case .sessionAccept: .sessionAccept
        case .sessionReject: .sessionReject
        case .sdpOffer: .sdpOffer
        case .sdpAnswer: .sdpAnswer
        case .iceCandidate: .iceCandidate
        case .sessionResume: .sessionResume
        case .sessionEnd: .sessionEnd
        }
    }

    /// Decodes and validates. Throws on any schema violation.
    public static func decode(type: SignalingType, from data: Data) throws -> SignalingPayload {
        let decoder = JSONDecoder()
        func dec<T: WirePayload>(_: T.Type) throws -> T {
            let value = try decoder.decode(T.self, from: data)
            try value.validate()
            return value
        }
        switch type {
        case .pairRequest: return .pairRequest(try dec(PairRequestPayload.self))
        case .pairResult: return .pairResult(try dec(PairResultPayload.self))
        case .sessionRequest: return .sessionRequest(try dec(SessionRequestPayload.self))
        case .sessionChallenge: return .sessionChallenge(try dec(SessionChallengePayload.self))
        case .sessionAuth: return .sessionAuth(try dec(SessionAuthPayload.self))
        case .sessionAccept: return .sessionAccept(try dec(SessionAcceptPayload.self))
        case .sessionReject: return .sessionReject(try dec(SessionRejectPayload.self))
        case .sdpOffer: return .sdpOffer(try dec(SdpOfferPayload.self))
        case .sdpAnswer: return .sdpAnswer(try dec(SdpAnswerPayload.self))
        case .iceCandidate: return .iceCandidate(try dec(IceCandidatePayload.self))
        case .sessionResume: return .sessionResume(try dec(SessionResumePayload.self))
        case .sessionEnd: return .sessionEnd(try dec(SessionEndPayload.self))
        }
    }

    /// Exact JSON bytes to place in an envelope. The signature covers these bytes.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        switch self {
        case .pairRequest(let p): return try e.encode(p)
        case .pairResult(let p): return try e.encode(p)
        case .sessionRequest(let p): return try e.encode(p)
        case .sessionChallenge(let p): return try e.encode(p)
        case .sessionAuth(let p): return try e.encode(p)
        case .sessionAccept(let p): return try e.encode(p)
        case .sessionReject(let p): return try e.encode(p)
        case .sdpOffer(let p): return try e.encode(p)
        case .sdpAnswer(let p): return try e.encode(p)
        case .iceCandidate(let p): return try e.encode(p)
        case .sessionResume(let p): return try e.encode(p)
        case .sessionEnd(let p): return try e.encode(p)
        }
    }
}
