import AppKit
import Foundation
import OwnDeskAgentCore
import OwnDeskControllerCore
import OwnDeskPeers
import OwnDeskProtocol
import OwnDeskTerminal

/// Another device asking to open terminals on this Mac, shown until someone here answers.
struct TerminalKeyRequest: Identifiable, Equatable {
    let deviceId: String
    let deviceName: String
    let deviceFingerprint: String
    let keyFingerprint: String
    let username: String
    var id: String { deviceId }
}

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
        // The address chosen for this Mac, as for the screen: the way to reach a Mac whose pairing
        // carried no Tailscale address.
        if let pin = addressPins[peer.deviceId], let host = Endpoints.url(for: pin)?.host { hosts.append(host) }
        if let found = discoveredPeer(for: peer.deviceId), let url = await Endpoints.resolve(found.endpoint), let host = url.host {
            hosts.append(host)
        }
        hosts += peer.addresses.compactMap { Endpoints.url(for: $0)?.host }
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }
    }

    // MARK: Keys, both ways

    /// The answer here to another device's request. Only a click reaches this.
    func answerTerminalKey(allow: Bool) {
        guard let agent else { return }
        Task { await agent.coordinator.resolveTerminalKey(approved: allow) }
    }

    static func describeTerminalKey(_ status: TerminalKeyStatus, device: String) -> String {
        switch status {
        case .installed: "\(device) can now open terminals on this Mac"
        case .alreadyInstalled: "\(device) could already open terminals on this Mac"
        case .denied: "refused terminal access to \(device)"
        case .expired: "\(device)'s terminal request went unanswered"
        case .busy: "\(device) asked for terminal access while another request was open"
        case .failed: "could not add \(device)'s key to authorized_keys"
        }
    }

    /// Asks another Mac to let this Mac's key in, and waits for someone there to answer. On a yes the
    /// login is saved and that Mac's host keys are pinned from its signed answer, so the first
    /// terminal needs neither a pasted line nor a fingerprint to compare. Returns what to tell the person.
    func requestTerminalKey(from peer: Peer, port: Int) async -> (ok: Bool, message: String) {
        var urls: [URL] = []
        if let pin = addressPins[peer.deviceId], let url = Endpoints.url(for: pin) { urls.append(url) }
        if let found = discoveredPeer(for: peer.deviceId), let url = await Endpoints.resolve(found.endpoint) { urls.append(url) }
        urls += peer.addresses.compactMap { Endpoints.url(for: $0) }
        let key = sshKey.authorizedKeysLine(comment: "")
        do {
            let answer = try await TerminalKeyClient.request(key: key, host: peer, urls: urls, identity: identity)
            switch answer.status {
            case .installed, .alreadyInstalled:
                saveTerminalSettings(TerminalSettings(username: answer.username, port: port), for: peer)
                let keys = answer.host_keys.compactMap { try? SSHHostKey(openSSH: $0) }
                knownHosts.pin(keys, for: peer.deviceId)
                append("\(peer.name) allowed this Mac's terminal key; logging in as \(answer.username)")
                return (true, answer.status == .installed
                        ? "\(peer.name) added this Mac's key. The terminal opens without a password."
                        : "\(peer.name) already had this Mac's key.")
            case .denied: return (false, "Someone on \(peer.name) said no, or it is not letting others in right now.")
            case .expired: return (false, "Nobody answered on \(peer.name) in time. Try again when someone is at it.")
            case .busy: return (false, "\(peer.name) is answering another request. Try again in a moment.")
            case .failed: return (false, "\(peer.name) could not write its authorized_keys file.")
            }
        } catch TerminalKeyClient.Failure.unreachable {
            return (false, "\(peer.name) did not answer. It has to be on, with \"Let others control it\" switched on.")
        } catch {
            return (false, "\(peer.name) did not answer in time.")
        }
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
