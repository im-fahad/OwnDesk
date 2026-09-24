import Foundation

/// Identity persistence in a 0600 file inside the app's data directory, for ad-hoc signed builds.
/// With a Secure Enclave the file holds only the key's opaque data representation, which is useless
/// on any other device; the private key itself never leaves the enclave. Without one, a software
/// key is stored, which is the same protection as the Keychain offers a software key.
public enum FileBackedIdentityStore {
    private struct Stored: Codable {
        var kind: String
        var key: Data
    }

    public static func loadOrCreate(at url: URL, preferSecureEnclave: Bool = true) throws -> any SigningIdentity {
        if let data = try? Data(contentsOf: url) {
            let stored: Stored
            do { stored = try JSONDecoder().decode(Stored.self, from: data) } catch { throw IdentityError.corruptStoredIdentity }
            switch stored.kind {
            case "secure-enclave":
                #if os(macOS)
                return try SecureEnclaveIdentity(dataRepresentation: stored.key)
                #else
                throw IdentityError.corruptStoredIdentity
                #endif
            case "software": return try SoftwareIdentity(rawRepresentation: stored.key)
            default: throw IdentityError.corruptStoredIdentity
            }
        }
        let identity: any SigningIdentity
        let stored: Stored
        #if os(macOS)
        if preferSecureEnclave, SecureEnclaveIdentity.isAvailable, let se = try? SecureEnclaveIdentity() {
            identity = se
            stored = Stored(kind: "secure-enclave", key: se.dataRepresentation)
        } else {
            let sw = SoftwareIdentity()
            identity = sw
            stored = Stored(kind: "software", key: sw.rawRepresentation)
        }
        #else
        let sw = SoftwareIdentity()
        identity = sw
        stored = Stored(kind: "software", key: sw.rawRepresentation)
        #endif
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(stored).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return identity
    }
}
