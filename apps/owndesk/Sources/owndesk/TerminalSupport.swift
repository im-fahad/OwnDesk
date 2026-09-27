import AppKit
import Foundation
import OwnDeskControllerCore
import OwnDeskPeers
import OwnDeskTerminal

/// How to log in to a Mac's terminal: its user name there, and the port its SSH server listens on.
struct TerminalSettings: Codable, Equatable {
    var username: String
    var port: Int = 22
}

/// The terminal half of the app state: this Mac's SSH key, the other Macs' pinned host keys, and
/// how to log in to each of them.
///
/// The terminal is the other Mac's own SSH server (Remote Login). OwnDesk's protocol never runs a
/// command; it only remembers how to reach the server and which key it presented last time.
extension AppState {
    static let terminalDefaultsKey = "terminalSettings"

    /// The line to add to `~/.ssh/authorized_keys` on a Mac, so the terminal opens without a password.
    var sshKeyLine: String { sshKey.authorizedKeysLine(comment: "OwnDesk on \(config.deviceName)") }

    /// A command that adds it, for pasting into Terminal on the other Mac.
    var sshKeyCommand: String {
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(sshKeyLine)' >> ~/.ssh/authorized_keys"
    }

    /// Opens a terminal on a Mac, asking how to log in first if that is not known yet.
    func openTerminal(_ peer: Peer) {
        guard peer.type == .mac else { return }
        guard let settings = terminalSettings[peer.deviceId], !settings.username.isEmpty else {
            terminalSetup = peer
            return
        }
        AppDelegate.showDockIcon(true)
        append("opening a terminal on \(peer.name) as \(settings.username)")
        TerminalWindowController.open(peer, settings: settings, state: self)
    }

    /// The hosts a Mac's SSH server might be reached at: where it is advertising itself right now,
    /// then every address it was known by, with OwnDesk's port dropped in favour of the SSH one.
    func terminalHosts(for peer: Peer) async -> [String] {
        var hosts: [String] = []
        if let found = discoveredPeer(for: peer.deviceId), let url = await Endpoints.resolve(found.endpoint), let host = url.host {
            hosts.append(host)
        }
        hosts += peer.addresses.compactMap { Endpoints.url(for: $0)?.host }
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }
    }

    func saveTerminalSettings(_ settings: TerminalSettings, for peer: Peer) {
        terminalSettings[peer.deviceId] = settings
        persistTerminalSettings()
    }

    /// Forgets the pinned SSH key of a Mac, so the next terminal asks about it again. For a Mac whose
    /// key really did change, such as after reinstalling macOS.
    func forgetHostKey(of peer: Peer) {
        knownHosts.forget(peer.deviceId)
        append("forgot the SSH key of \(peer.name)")
    }

    /// Unpairing a Mac forgets how to log in to it and the key it presented.
    func forgetTerminal(_ deviceId: String) {
        if terminalSettings.removeValue(forKey: deviceId) != nil { persistTerminalSettings() }
        knownHosts.forget(deviceId)
    }

    private func persistTerminalSettings() {
        UserDefaults.standard.set(try? JSONEncoder().encode(terminalSettings), forKey: Self.terminalDefaultsKey)
    }

    static func loadTerminalSettings() -> [String: TerminalSettings] {
        UserDefaults.standard.data(forKey: terminalDefaultsKey)
            .flatMap { try? JSONDecoder().decode([String: TerminalSettings].self, from: $0) } ?? [:]
    }

    /// This Mac's SSH key, made on first use. A key the Mac cannot use, such as an enclave key
    /// restored from another Mac's backup, is replaced and said so.
    static func loadSSHKey(at file: URL, notes: inout [String]) -> SSHDeviceKey {
        if let key = try? SSHDeviceKey.loadOrCreate(at: file) { return key }
        try? FileManager.default.removeItem(at: file)
        notes.append("the terminal key could not be used, so this Mac has a new one; add it on each Mac again")
        if let key = try? SSHDeviceKey.loadOrCreate(at: file) { return key }
        // Last resort: a key for this run only, so the app still starts.
        return try! SSHDeviceKey.loadOrCreate(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("owndesk-ssh-key.json"), preferSecureEnclave: false)
    }
}
