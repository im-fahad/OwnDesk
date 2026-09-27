import CryptoKit
import Foundation
import NIOSSH

/// This device's SSH key: the key a Mac's `authorized_keys` lists to let it log in.
///
/// It is a key of its own, not the device's OwnDesk identity. The two sign for different protocols,
/// and keeping them apart means nothing signed for one can ever be replayed as the other.
///
/// P-256, because that is the curve the Secure Enclave holds: where there is one, the private key
/// never leaves it and the file keeps only its opaque handle, useless on any other device. OpenSSH
/// accepts it as `ecdsa-sha2-nistp256`. The Simulator has no enclave and gets a software key.
public struct SSHDeviceKey: Sendable {
    public let privateKey: NIOSSHPrivateKey
    /// "Secure Enclave" or "software", for saying where the key lives.
    public let storage: String

    public var publicKey: NIOSSHPublicKey { privateKey.publicKey }

    /// The line for a Mac's `~/.ssh/authorized_keys`: type, key and a comment naming this device.
    public func authorizedKeysLine(comment: String) -> String {
        let clean = comment.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return String(openSSHPublicKey: publicKey) + (clean.isEmpty ? "" : " \(clean)")
    }

    public var fingerprint: String { HostKeys.fingerprint(of: publicKey) }

    public enum KeyError: Error, Equatable, Sendable {
        case unreadable
    }

    private struct Stored: Codable {
        var kind: String
        var key: Data
    }

    /// Loads the key stored at `url`, or makes one and stores it there, readable by this user only.
    public static func loadOrCreate(at url: URL, preferSecureEnclave: Bool = true) throws -> SSHDeviceKey {
        if let data = try? Data(contentsOf: url) {
            guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { throw KeyError.unreadable }
            switch stored.kind {
            case "secure-enclave":
                guard SecureEnclave.isAvailable,
                      let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored.key)
                else { throw KeyError.unreadable }
                return SSHDeviceKey(privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: key), storage: "Secure Enclave")
            case "software":
                guard let key = try? P256.Signing.PrivateKey(rawRepresentation: stored.key) else { throw KeyError.unreadable }
                return SSHDeviceKey(privateKey: NIOSSHPrivateKey(p256Key: key), storage: "software")
            default:
                throw KeyError.unreadable
            }
        }

        let made: SSHDeviceKey
        let stored: Stored
        if preferSecureEnclave, SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            made = SSHDeviceKey(privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: key), storage: "Secure Enclave")
            stored = Stored(kind: "secure-enclave", key: key.dataRepresentation)
        } else {
            let key = P256.Signing.PrivateKey()
            made = SSHDeviceKey(privateKey: NIOSSHPrivateKey(p256Key: key), storage: "software")
            stored = Stored(kind: "software", key: key.rawRepresentation)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return made
    }
}
