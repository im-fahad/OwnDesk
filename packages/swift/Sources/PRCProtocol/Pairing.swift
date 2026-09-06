import CryptoKit
import Foundation
import PRCIdentity

/// Pairing (spec section 7): QR payload and HMAC proof of QR possession.
public enum Pairing {
    public static let context = "prc-pairing-v1"
    public static let ttlMs: Int64 = 120_000
    public static let maxFailedProofs = 3
    public static let secretBytes = 16

    public static func randomSecret() -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<secretBytes).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }

    public static func proofInput(pairingSessionId: String, controllerDeviceId: String) -> Data {
        Data("\(context)\n\(pairingSessionId)\n\(controllerDeviceId)".utf8)
    }

    public static func proof(pairingCode: Data, pairingSessionId: String, controllerDeviceId: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: proofInput(pairingSessionId: pairingSessionId, controllerDeviceId: controllerDeviceId), using: SymmetricKey(data: pairingCode))
        return Base64URL.encode(Data(mac))
    }

    /// Constant-time comparison via CryptoKit.
    public static func verifyProof(pairingCode: Data, pairingSessionId: String, controllerDeviceId: String, proof: String) -> Bool {
        guard let mac = Base64URL.decode(proof), mac.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: proofInput(pairingSessionId: pairingSessionId, controllerDeviceId: controllerDeviceId), using: SymmetricKey(data: pairingCode))
    }
}

public struct QRPayload: Codable, Sendable, Equatable {
    public var v: Int
    public var kind: String
    public var host_device_id: String
    public var host_key_hash: String
    public var host_name: String
    public var addresses: [String]
    public var rendezvous_url: String?
    public var pairing_session_id: String
    public var pairing_code: String
    public var expires_at: Int64

    enum CodingKeys: String, CodingKey { case v, kind, host_device_id, host_key_hash, host_name, addresses, rendezvous_url, pairing_session_id, pairing_code, expires_at }

    public init(hostDeviceId: String, hostName: String, addresses: [String], rendezvousUrl: String?, pairingSessionId: String, pairingCode: Data, now: Int64) {
        v = Envelope.protocolVersion
        kind = "prc-pair"
        host_device_id = hostDeviceId
        host_key_hash = hostDeviceId
        host_name = hostName
        self.addresses = addresses
        rendezvous_url = rendezvousUrl
        pairing_session_id = pairingSessionId
        pairing_code = Base64URL.encode(pairingCode)
        expires_at = now + Pairing.ttlMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        kind = try c.decode(String.self, forKey: .kind)
        host_device_id = try c.decode(String.self, forKey: .host_device_id)
        host_key_hash = try c.decode(String.self, forKey: .host_key_hash)
        host_name = try c.decode(String.self, forKey: .host_name)
        addresses = try c.decode([String].self, forKey: .addresses)
        rendezvous_url = try c.decodeIfPresent(String.self, forKey: .rendezvous_url)
        pairing_session_id = try c.decode(String.self, forKey: .pairing_session_id)
        pairing_code = try c.decode(String.self, forKey: .pairing_code)
        expires_at = try c.decode(Int64.self, forKey: .expires_at)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(kind, forKey: .kind)
        try c.encode(host_device_id, forKey: .host_device_id)
        try c.encode(host_key_hash, forKey: .host_key_hash)
        try c.encode(host_name, forKey: .host_name)
        try c.encode(addresses, forKey: .addresses)
        if let rendezvous_url { try c.encode(rendezvous_url, forKey: .rendezvous_url) } else { try c.encodeNil(forKey: .rendezvous_url) }
        try c.encode(pairing_session_id, forKey: .pairing_session_id)
        try c.encode(pairing_code, forKey: .pairing_code)
        try c.encode(expires_at, forKey: .expires_at)
    }

    public func validate() throws {
        try Wire.require(kind == "prc-pair", "kind")
        try Wire.require(DeviceID.isValid(host_device_id) && host_key_hash == host_device_id, "host_device_id")
        try Wire.require(Wire.isDeviceName(host_name), "host_name")
        try Wire.require((1...16).contains(addresses.count) && addresses.allSatisfy { (3...128).contains($0.count) }, "addresses")
        if let rendezvous_url { try Wire.require(Wire.isWsUrl(rendezvous_url), "rendezvous_url") }
        try Wire.require(Wire.isBytes16(pairing_session_id), "pairing_session_id")
        try Wire.require(Wire.isBytes16(pairing_code), "pairing_code")
    }

    public var pairingCodeBytes: Data? { Base64URL.decode(pairing_code) }
}
