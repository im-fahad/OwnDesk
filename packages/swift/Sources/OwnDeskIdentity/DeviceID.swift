import CryptoKit
import Foundation

public enum IdentityError: Error, Equatable, Sendable {
    case invalidPublicKey
    case invalidDeviceId
    case invalidPrivateKey
    case secureEnclaveUnavailable
    case keychain(OSStatus)
    case corruptStoredIdentity
}

/// Device identity encodings (spec section 5.2).
public enum DeviceID {
    public static let publicKeyBytes = 65
    public static let signatureBytes = 64

    /// A public key on the wire is the 65-byte X9.63 uncompressed point: 0x04 || X || Y.
    public static func validatePublicKey(_ raw: Data) throws {
        guard raw.count == publicKeyBytes, raw.first == 0x04 else { throw IdentityError.invalidPublicKey }
    }

    /// Lowercase hex SHA-256 of the 65 public key bytes.
    public static func deviceId(publicKeyRaw raw: Data) throws -> String {
        try validatePublicKey(raw)
        return Hex.encode(Data(SHA256.hash(data: raw)))
    }

    public static func isValid(_ deviceId: String) -> Bool {
        Hex.isLowercaseHex(deviceId, count: 64)
    }

    /// First 12 hex characters as XXXX-XXXX-XXXX, upper case. What users compare during pairing.
    public static func fingerprint(deviceId: String) throws -> String {
        guard isValid(deviceId) else { throw IdentityError.invalidDeviceId }
        let h = Array(deviceId.prefix(12).uppercased())
        return "\(String(h[0..<4]))-\(String(h[4..<8]))-\(String(h[8..<12]))"
    }
}
