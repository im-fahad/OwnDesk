import CryptoKit
import Foundation

/// Something that can sign with a device identity key. The private key never leaves the implementation.
public protocol SigningIdentity: Sendable {
    /// 65-byte X9.63 uncompressed public key.
    var publicKeyRaw: Data { get }
    var deviceId: String { get }
    /// ECDSA P-256 with SHA-256. Returns raw r||s, 64 bytes.
    func sign(_ data: Data) throws -> Data
}

public extension SigningIdentity {
    var publicKeyB64: String { Base64URL.encode(publicKeyRaw) }
    var fingerprint: String { (try? DeviceID.fingerprint(deviceId: deviceId)) ?? "" }
}

public enum Verifier {
    /// Verifies a raw r||s signature over `data` with a wire-encoded public key. Never throws.
    public static func verify(publicKeyRaw: Data, data: Data, signature: Data) -> Bool {
        guard signature.count == DeviceID.signatureBytes,
              (try? DeviceID.validatePublicKey(publicKeyRaw)) != nil,
              let key = try? P256.Signing.PublicKey(x963Representation: publicKeyRaw),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature)
        else { return false }
        return key.isValidSignature(sig, for: data)
    }
}

/// A P-256 key held in process memory. Used on Macs without a Secure Enclave and in tests.
public struct SoftwareIdentity: SigningIdentity, @unchecked Sendable {
    private let key: P256.Signing.PrivateKey
    public let publicKeyRaw: Data
    public let deviceId: String

    public init() {
        self.init(key: P256.Signing.PrivateKey())
    }

    public init(key: P256.Signing.PrivateKey) {
        self.key = key
        self.publicKeyRaw = key.publicKey.x963Representation
        self.deviceId = Hex.encode(Data(SHA256.hash(data: publicKeyRaw)))
    }

    /// 32-byte private scalar, as stored in the Keychain.
    public init(rawRepresentation: Data) throws {
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: rawRepresentation) else { throw IdentityError.invalidPrivateKey }
        self.init(key: key)
    }

    /// From the `d` member of a JWK. Test vectors only.
    public init(jwkD: String) throws {
        guard let d = Base64URL.decode(jwkD), d.count == 32 else { throw IdentityError.invalidPrivateKey }
        try self.init(rawRepresentation: d)
    }

    public var rawRepresentation: Data { key.rawRepresentation }

    public func sign(_ data: Data) throws -> Data {
        try key.signature(for: data).rawRepresentation
    }
}
