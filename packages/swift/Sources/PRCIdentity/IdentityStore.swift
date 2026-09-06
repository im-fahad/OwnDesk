#if os(macOS)
import Foundation
import Security

/// Persists the device identity in the login Keychain as a generic password item.
/// Secure Enclave keys are stored as their opaque data representation. Software keys as the raw scalar.
public enum IdentityStore {
    private struct Stored: Codable {
        var kind: String
        var key: Data
    }

    public static func loadOrCreate(service: String, account: String = "device-identity", preferSecureEnclave: Bool = true) throws -> any SigningIdentity {
        if let data = try read(service: service, account: account) {
            let stored: Stored
            do { stored = try JSONDecoder().decode(Stored.self, from: data) } catch { throw IdentityError.corruptStoredIdentity }
            switch stored.kind {
            case "secure-enclave": return try SecureEnclaveIdentity(dataRepresentation: stored.key)
            case "software": return try SoftwareIdentity(rawRepresentation: stored.key)
            default: throw IdentityError.corruptStoredIdentity
            }
        }

        let identity: any SigningIdentity
        let stored: Stored
        if preferSecureEnclave, SecureEnclaveIdentity.isAvailable, let se = try? SecureEnclaveIdentity() {
            identity = se
            stored = Stored(kind: "secure-enclave", key: se.dataRepresentation)
        } else {
            let sw = SoftwareIdentity()
            identity = sw
            stored = Stored(kind: "software", key: sw.rawRepresentation)
        }
        try write(service: service, account: account, data: try JSONEncoder().encode(stored))
        return identity
    }

    public static func delete(service: String, account: String = "device-identity") throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IdentityError.keychain(status) }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
        return out as? Data
    }

    private static func write(service: String, account: String, data: Data) throws {
        var add = baseQuery(service: service, account: account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "PRC device identity"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(baseQuery(service: service, account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw IdentityError.keychain(update) }
            return
        }
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
    }
}
#endif
