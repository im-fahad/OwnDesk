import CryptoKit
import Foundation
import NIOSSH

/// A Mac's SSH host key, and whether it is the one this device has seen before.
///
/// SSH's defence against someone in the middle is that the client knows the server's key. The first
/// time it cannot, so the person is shown the key's fingerprint and decides; after that the key is
/// pinned, and a different one is refused outright rather than asked about, because a changed host
/// key is exactly what an interception looks like.
public enum HostKeys {
    /// OpenSSH's form, as `ssh-keygen -l` prints it: "SHA256:" and the unpadded base64 of the
    /// SHA-256 of the key's wire encoding.
    public static func fingerprint(of key: NIOSSHPublicKey) -> String {
        let fields = String(openSSHPublicKey: key).split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return "" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + digest
    }

    /// Type and key only, the part that identifies a key, with any comment dropped.
    public static func canonical(_ openSSH: String) -> String? {
        let fields = openSSH.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        return "\(fields[0]) \(fields[1])"
    }

    public static func canonical(_ key: NIOSSHPublicKey) -> String {
        canonical(String(openSSHPublicKey: key)) ?? String(openSSHPublicKey: key)
    }
}

/// A Mac's SSH host key, as the apps see it: what it is called, its fingerprint, and the text that
/// identifies it. SwiftNIO SSH's own type stays inside this package.
public struct SSHHostKey: Sendable, Hashable {
    let key: NIOSSHPublicKey

    init(_ key: NIOSSHPublicKey) {
        self.key = key
    }

    /// From OpenSSH's text form, "ssh-ed25519 AAAA… comment".
    public init(openSSH: String) throws {
        key = try NIOSSHPublicKey(openSSHPublicKey: openSSH)
    }

    /// "ssh-ed25519 AAAA…", without a comment.
    public var openSSH: String { HostKeys.canonical(key) }
    /// "ssh-ed25519", "ecdsa-sha2-nistp256" and so on.
    public var type: String { openSSH.split(separator: " ").first.map(String.init) ?? "" }
    public var fingerprint: String { HostKeys.fingerprint(of: key) }
}

/// What to do with a host key the server presented.
public enum HostKeyVerdict: Equatable, Sendable {
    /// The pinned key: go ahead.
    case known
    /// Nothing is pinned for this Mac yet: ask the person, showing the fingerprint.
    case new(fingerprint: String)
    /// A different key from the pinned one: refuse.
    case changed(fingerprint: String)
}

/// The pinned host key of each Mac, by the Mac's OwnDesk device id, in one small file.
public final class KnownHosts: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func verdict(for key: SSHHostKey, of deviceId: String) -> HostKeyVerdict {
        guard let pinned = load()[deviceId] else { return .new(fingerprint: key.fingerprint) }
        return pinned == key.openSSH ? .known : .changed(fingerprint: key.fingerprint)
    }

    public func pin(_ key: SSHHostKey, for deviceId: String) {
        update { $0[deviceId] = key.openSSH }
    }

    public func forget(_ deviceId: String) {
        update { $0[deviceId] = nil }
    }

    /// The pinned key, if there is one.
    public func pinned(_ deviceId: String) -> SSHHostKey? {
        load()[deviceId].flatMap { try? SSHHostKey(openSSH: $0) }
    }

    private func load() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func update(_ change: (inout [String: String]) -> Void) {
        var all = load()
        change(&all)
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(all).write(to: url, options: [.atomic])
        // Public keys only, but kept like the rest of the data folder: readable by this user alone.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
