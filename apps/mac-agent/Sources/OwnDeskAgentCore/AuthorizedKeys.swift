import CryptoKit
import Foundation

/// This Mac's `~/.ssh/authorized_keys`, as far as OwnDesk touches it: a paired device's terminal key
/// goes in after a click here, and comes out again when that device is unpaired.
///
/// The line is always built here from a key type and a key, never taken from the device, so no
/// `command=` or other option can ride in with it. Each line carries a tag naming the device it
/// belongs to, and removal matches that tag alone: a key someone added by hand is never touched.
public struct AuthorizedKeys: Sendable {
    public let file: URL

    public init(file: URL = AuthorizedKeys.standardFile) {
        self.file = file
    }

    public static var standardFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/authorized_keys")
    }

    /// The account the key logs in to: whoever runs this app.
    public static var username: String { NSUserName() }

    /// "owndesk-" and the first 16 hex characters of the device id, in the line's comment.
    public static func tag(for deviceId: String) -> String { "owndesk-\(deviceId.prefix(16))" }

    public enum Outcome: Equatable, Sendable { case installed, alreadyInstalled }

    /// Whether a line already lets this key in, whatever its comment or options.
    public func contains(key: String) -> Bool {
        guard let wanted = Self.canonical(key) else { return false }
        return lines().contains { Self.keyInLine($0) == wanted }
    }

    /// Adds the key for a device, unless it is already there. Creates `~/.ssh` and the file readable
    /// by this user only, which OpenSSH's StrictModes insists on.
    @discardableResult
    public func install(key: String, deviceId: String, deviceName: String) throws -> Outcome {
        guard let canonical = Self.canonical(key) else { throw CocoaError(.fileWriteInvalidFileName) }
        if contains(key: canonical) { return .alreadyInstalled }
        let directory = file.deletingLastPathComponent()
        let files = FileManager.default
        if !files.fileExists(atPath: directory.path) {
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if !files.fileExists(atPath: file.path) {
            guard files.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        let line = "\(canonical) \(Self.tag(for: deviceId)) \(Self.cleanName(deviceName))\n"
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        // Start on a line of its own if the file does not end with one.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let last = try handle.read(upToCount: 1)
            try handle.seekToEnd()
            if last != Data("\n".utf8) { try handle.write(contentsOf: Data("\n".utf8)) }
        }
        try handle.write(contentsOf: Data(line.utf8))
        return .installed
    }

    /// Removes every line OwnDesk added for this device. Returns how many went.
    @discardableResult
    public func remove(deviceId: String) throws -> Int {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return 0 }
        let tag = Self.tag(for: deviceId)
        var kept: [Substring] = []
        var removed = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.split(separator: " ").contains(Substring(tag)) { removed += 1 } else { kept.append(line) }
        }
        guard removed > 0 else { return 0 }
        // Rewritten in place, so the file keeps its owner, mode and any link pointing at it.
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(kept.joined(separator: "\n").utf8))
        return removed
    }

    /// This Mac's SSH host keys, "type key" each, as the device will see them when it connects.
    public static func hostKeys(directory: URL = URL(fileURLWithPath: "/etc/ssh")) -> [String] {
        ["ssh_host_ed25519_key.pub", "ssh_host_ecdsa_key.pub", "ssh_host_rsa_key.pub"].compactMap { name in
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { return nil }
            return canonical(text.trimmingCharacters(in: .whitespacesAndNewlines), anyType: true)
        }
    }

    /// OpenSSH's fingerprint of a "type key" line: "SHA256:" and the unpadded base64 of the key's hash.
    public static func fingerprint(of key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "" }
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    // MARK: Parsing

    static let deviceKeyTypes: Set<String> = ["ecdsa-sha2-nistp256", "ssh-ed25519"]
    static let allKeyTypes: Set<String> = deviceKeyTypes.union(["ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa"])

    /// "type key" from "type key [comment]", or nil when it is not a key of a type we take.
    static func canonical(_ text: String, anyType: Bool = false) -> String? {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, (anyType ? allKeyTypes : deviceKeyTypes).contains(String(parts[0])),
              Data(base64Encoded: String(parts[1])) != nil else { return nil }
        return "\(parts[0]) \(parts[1])"
    }

    /// The "type key" in an authorized_keys line, which may start with options.
    static func keyInLine(_ line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let tokens = trimmed.split(separator: " ")
        for (index, token) in tokens.enumerated() where allKeyTypes.contains(String(token)) && index + 1 < tokens.count {
            return "\(token) \(tokens[index + 1])"
        }
        return nil
    }

    /// A device name made safe for a comment: printable ASCII, no quotes, short.
    static func cleanName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-_()'"))
        let cleaned = String(name.unicodeScalars.map { $0.isASCII && allowed.contains($0) ? Character($0) : "-" })
        return String(cleaned.prefix(40)).trimmingCharacters(in: .whitespaces)
    }

    private func lines() -> [Substring] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
    }
}
