import Foundation
import NIOSSH
import OwnDeskTerminal
import Testing

/// Everything a terminal printed, and how it ended, for waiting on.
final class Transcript: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var status: Int?
    private var ended = false

    init(_ terminal: SSHTerminal) {
        Task { [self] in
            for await event in terminal.events {
                lock.withLock {
                    switch event {
                    case .output(let bytes): text += String(decoding: bytes, as: UTF8.self)
                    case .exitStatus(let code): status = code
                    case .closed: ended = true
                    }
                }
            }
        }
    }

    var exitStatus: Int? { lock.withLock { status } }

    func wait(for needle: String, timeoutSeconds: Double = 15) async throws {
        try await until("output containing \(needle)", timeoutSeconds) { self.lock.withLock { self.text.contains(needle) } }
    }

    func waitForEnd(timeoutSeconds: Double = 15) async throws {
        try await until("the end", timeoutSeconds) { self.lock.withLock { self.ended } }
    }

    private func until(_ what: String, _ seconds: Double, _ done: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > deadline {
                let seen = lock.withLock { text.suffix(400) }
                Issue.record("timed out waiting for \(what); last output: \(seen)")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

private func freshKey() throws -> SSHDeviceKey {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("owndesk-ssh-key-\(UUID().uuidString).json")
    return try SSHDeviceKey.loadOrCreate(at: url, preferSecureEnclave: false)
}

@Suite(.serialized, .enabled(if: PrivateSSHD.isAvailable))
struct SSHTerminalTests {
    @Test func aKeyLoginOpensAShellThatRunsWhatIsTyped() async throws {
        let key = try freshKey()
        let server = try PrivateSSHD(authorizedKeys: [key.authorizedKeysLine(comment: "owndesk test")])
        defer { server.stop() }

        let terminal = SSHTerminal()
        let transcript = Transcript(terminal)
        try await terminal.connect(host: "127.0.0.1", port: server.port, username: NSUserName(), key: key,
                                   hostKey: { _ in true }, options: .init(columns: 80, rows: 24))
        // The answer, not the command: the typed line echoes back with $((…)) unexpanded.
        terminal.send("echo owndesk-$((40+2))\n")
        try await transcript.wait(for: "owndesk-42")
        terminal.send("echo term=$TERM\n")
        try await transcript.wait(for: "term=xterm-256color")
        terminal.send("stty size\n")
        try await transcript.wait(for: "24 80")

        // A rotated phone is a different terminal: the shell has to hear about it.
        terminal.resize(columns: 100, rows: 30)
        terminal.send("stty size\n")
        try await transcript.wait(for: "30 100")

        terminal.send("exit 3\n")
        try await transcript.waitForEnd()
        #expect(transcript.exitStatus == 3)
    }

    @Test func anUntrustedHostKeyEndsItBeforeAnythingIsSent() async throws {
        let key = try freshKey()
        let server = try PrivateSSHD(authorizedKeys: [key.authorizedKeysLine(comment: "")])
        defer { server.stop() }
        await #expect(throws: SSHTerminalError.hostKeyRejected) {
            try await SSHTerminal().connect(host: "127.0.0.1", port: server.port, username: NSUserName(), key: key,
                                            hostKey: { _ in false })
        }
    }

    @Test func aKeyTheMacDoesNotListIsRefused() async throws {
        let listed = try freshKey()
        let stranger = try freshKey()
        let server = try PrivateSSHD(authorizedKeys: [listed.authorizedKeysLine(comment: "")])
        defer { server.stop() }
        await #expect(throws: SSHTerminalError.authenticationFailed) {
            try await SSHTerminal().connect(host: "127.0.0.1", port: server.port, username: NSUserName(), key: stranger,
                                            hostKey: { _ in true })
        }
    }

    /// With the key refused, the person is asked for a password, once. Declining says so; a wrong
    /// one is a failed login. (This server cannot check passwords, so none ever succeeds.)
    @Test func thePasswordIsAskedForOnlyWhenTheKeyIsRefused() async throws {
        let listed = try freshKey()
        let stranger = try freshKey()
        let server = try PrivateSSHD(authorizedKeys: [listed.authorizedKeysLine(comment: "")], passwords: true)
        defer { server.stop() }

        let asked = Counter()
        await #expect(throws: SSHTerminalError.cancelled) {
            try await SSHTerminal().connect(host: "127.0.0.1", port: server.port, username: NSUserName(), key: stranger,
                                            password: { asked.increment(); return nil }, hostKey: { _ in true })
        }
        #expect(asked.value == 1)

        await #expect(throws: SSHTerminalError.authenticationFailed) {
            try await SSHTerminal().connect(host: "127.0.0.1", port: server.port, username: NSUserName(), key: stranger,
                                            password: { "not the password" }, hostKey: { _ in true })
        }

        // The listed key goes straight in: no password prompt at all.
        let neverAsked = Counter()
        let terminal = SSHTerminal()
        try await terminal.connect(host: "127.0.0.1", port: server.port, username: NSUserName(), key: listed,
                                   password: { neverAsked.increment(); return nil }, hostKey: { _ in true })
        terminal.close()
        #expect(neverAsked.value == 0)
    }

    @Test func theFingerprintShownIsTheOneOpenSSHPrints() async throws {
        let key = try freshKey()
        let server = try PrivateSSHD(authorizedKeys: [key.authorizedKeysLine(comment: "")])
        defer { server.stop() }
        let seen = Box<SSHHostKey?>(nil)
        let terminal = SSHTerminal()
        try await terminal.connect(host: "127.0.0.1", port: server.port, username: NSUserName(), key: key,
                                   hostKey: { seen.set($0); return true })
        terminal.close()
        let hostKey = try #require(seen.get())
        #expect(hostKey.fingerprint == (try server.openSSHFingerprint()))
        #expect(hostKey.openSSH == HostKeys.canonical(server.hostPublicKey))
        #expect(hostKey.type == "ssh-ed25519")
    }

    @Test func nothingListeningIsUnreachable() async throws {
        let key = try freshKey()
        await #expect(throws: SSHTerminalError.unreachable("127.0.0.1:1")) {
            try await SSHTerminal().connect(host: "127.0.0.1", port: 1, username: NSUserName(), key: key,
                                            hostKey: { _ in true }, options: .init(connectTimeoutSeconds: 2))
        }
    }
}

@Suite struct SSHKeyTests {
    @Test func theDeviceKeyIsKeptAndItsLineIsOneOpenSSHReads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("owndesk-ssh-key-\(UUID().uuidString).json")
        let first = try SSHDeviceKey.loadOrCreate(at: url, preferSecureEnclave: false)
        let again = try SSHDeviceKey.loadOrCreate(at: url, preferSecureEnclave: false)
        #expect(first.publicKey == again.publicKey, "a new key on every launch would lock the device out")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let line = first.authorizedKeysLine(comment: "OwnDesk on iPhone")
        #expect(line.hasPrefix("ecdsa-sha2-nistp256 "))
        #expect(line.hasSuffix(" OwnDesk on iPhone"))
        let file = url.deletingPathExtension().appendingPathExtension("pub")
        try line.write(to: file, atomically: true, encoding: .utf8)
        let printed = try PrivateSSHD.run("/usr/bin/ssh-keygen", ["-l", "-f", file.path])
        #expect(printed.contains(first.fingerprint), "ssh-keygen read \(printed)")
    }

    @Test func aDamagedKeyFileIsReportedNotReplaced() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("owndesk-ssh-key-\(UUID().uuidString).json")
        try Data("not a key".utf8).write(to: url)
        #expect(throws: SSHDeviceKey.KeyError.unreadable) { try SSHDeviceKey.loadOrCreate(at: url, preferSecureEnclave: false) }
    }

    /// A key seen before is trusted, a new one is asked about, and a different one is refused: a
    /// changed host key is what someone in the middle looks like.
    @Test func hostKeysArePinnedPerMac() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("owndesk-known-\(UUID().uuidString).json")
        let hosts = KnownHosts(url: url)
        let first = try SSHHostKey(openSSH: freshKey().authorizedKeysLine(comment: "one"))
        let other = try SSHHostKey(openSSH: freshKey().authorizedKeysLine(comment: "two"))

        #expect(hosts.verdict(for: first, of: "mac-a") == .new(fingerprint: first.fingerprint))
        hosts.pin(first, for: "mac-a")
        #expect(hosts.verdict(for: first, of: "mac-a") == .known)
        #expect(hosts.pinned("mac-a") == first)
        #expect(hosts.verdict(for: other, of: "mac-a") == .changed(fingerprint: other.fingerprint))
        #expect(hosts.verdict(for: first, of: "mac-b") == .new(fingerprint: first.fingerprint), "pins are per Mac")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600, "readable by this user only, like the rest of the data folder")

        // Several keys vouched for at once: each is known, anything else is still a change.
        let third = try SSHHostKey(openSSH: freshKey().authorizedKeysLine(comment: "three"))
        hosts.pin([first, other], for: "mac-c")
        #expect(hosts.verdict(for: first, of: "mac-c") == .known)
        #expect(hosts.verdict(for: other, of: "mac-c") == .known)
        #expect(hosts.verdict(for: third, of: "mac-c") == .changed(fingerprint: third.fingerprint))
        #expect(hosts.pinnedAll("mac-c").count == 2)

        // Kept on disk, and forgetting a Mac clears its pin.
        #expect(KnownHosts(url: url).verdict(for: first, of: "mac-a") == .known)
        hosts.forget("mac-a")
        #expect(hosts.pinned("mac-a") == nil)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ new: T) { lock.withLock { value = new } }
}
