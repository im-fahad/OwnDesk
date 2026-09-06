import CryptoKit
import Foundation

/// A P-256 key that lives in the Secure Enclave. `dataRepresentation` is an opaque blob that only
/// this device can use, so storing it in the Keychain does not expose the private key.
public struct SecureEnclaveIdentity: SigningIdentity, @unchecked Sendable {
    private let key: SecureEnclave.P256.Signing.PrivateKey
    public let publicKeyRaw: Data
    public let deviceId: String

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public init() throws {
        guard SecureEnclave.isAvailable else { throw IdentityError.secureEnclaveUnavailable }
        self.init(key: try SecureEnclave.P256.Signing.PrivateKey())
    }

    public init(dataRepresentation: Data) throws {
        guard SecureEnclave.isAvailable else { throw IdentityError.secureEnclaveUnavailable }
        guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation) else {
            throw IdentityError.corruptStoredIdentity
        }
        self.init(key: key)
    }

    init(key: SecureEnclave.P256.Signing.PrivateKey) {
        self.key = key
        self.publicKeyRaw = key.publicKey.x963Representation
        self.deviceId = Hex.encode(Data(SHA256.hash(data: publicKeyRaw)))
    }

    public var dataRepresentation: Data { key.dataRepresentation }

    public func sign(_ data: Data) throws -> Data {
        try key.signature(for: data).rawRepresentation
    }
}
