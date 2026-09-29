import Foundation
import OwnDeskAgentCore
import OwnDeskIdentity
import OwnDeskPeers
import OwnDeskProtocol
import Testing
@testable import OwnDeskControllerCore

/// TERMINAL_KEY_REQUEST against a real in-process host: nothing is installed without the person's
/// answer, the answer is signed, and unpairing takes the key away again. Part of the end-to-end suite,
/// so it never pairs at the same moment as another test: the pairing client checks one host at a time.
extension ControllerEndToEndTests {
    static let terminalKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHM2Sr2uFsXzDlrzGmbqLS9n0hyXU6oiWtD4H3WOs/Oe1h1r8e2/pzVuVp9lPbZ55W3k/LOZr8Fd9gV5IwqSLXg="

    /// A host whose answer to a key request is `approve`, and a device paired with it.
    private func pairForTerminalKey(approve: Bool?) async throws -> (Agent, SoftwareIdentity, Peer, URL, Box<[AgentEvent]>) {
        let (agent, events) = try await E2E.startAgent(media: false)
        if let approve {
            // The harness already reads the host's events into `events`; a second reader would take
            // some of them away from it, so this answers from the record instead.
            let coordinator = agent.coordinator
            Task {
                var answered = 0
                while !Task.isCancelled {
                    let asked = events.get().filter { if case .terminalKeyRequest = $0 { return true } else { return false } }.count
                    if asked > answered { answered = asked; await coordinator.resolveTerminalKey(approved: approve) }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        let address = "127.0.0.1:\(agent.port)"
        let identity = SoftwareIdentity()
        let qr = await agent.coordinator.openPairing()
        let outcome = try await PairingClient(identity: identity, deviceName: "Test Phone").pair(qr: qr, preferredAddress: address)
        return (agent, identity, outcome.host, try #require(Endpoints.url(for: address)), events)
    }

    private func keysFileText(_ agent: Agent) -> String {
        (try? String(contentsOf: agent.config.dataDirectory.appendingPathComponent("authorized_keys"), encoding: .utf8)) ?? ""
    }

    @Test func anAllowedKeyIsInstalledAndTheAnswerCarriesTheAccountAndHostKeys() async throws {
        let (agent, identity, host, url, events) = try await pairForTerminalKey(approve: true)
        let answer = try await TerminalKeyClient.request(key: Self.terminalKey, host: host, urls: [url], identity: identity)
        #expect(answer.status == .installed)
        #expect(answer.username == NSUserName())
        #expect(answer.host_keys == AuthorizedKeys.hostKeys(), "the Mac's own host keys, as sshd will present them")

        // One line, built by the host: the key, a tag naming the device, and its name.
        let lines = keysFileText(agent).split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines.first?.hasPrefix(Self.terminalKey + " owndesk-\(identity.deviceId.prefix(16)) Test Phone") == true)
        let mode = try FileManager.default.attributesOfItem(atPath: agent.config.dataDirectory.appendingPathComponent("authorized_keys").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(events.get().contains { if case .terminalKeyResolved(_, .installed) = $0 { return true } else { return false } })

        // Asking again is answered at once, without a second question or a second line.
        let again = try await TerminalKeyClient.request(key: Self.terminalKey, host: host, urls: [url], identity: identity)
        #expect(again.status == .alreadyInstalled)
        #expect(keysFileText(agent).split(separator: "\n").count == 1)

        // Unpairing takes the key away, and leaves lines someone added by hand alone.
        let path = agent.config.dataDirectory.appendingPathComponent("authorized_keys")
        try (keysFileText(agent) + "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHandAddedKeyHandAddedKeyHandAddedKey00 me@laptop\n").write(to: path, atomically: false, encoding: .utf8)
        #expect(await UnpairClient.send(to: agent.identity.deviceId, urls: [url], identity: identity))
        try await E2E.waitUntil("the host forgets the device") { agent.peers.peer(identity.deviceId) == nil }
        #expect(!keysFileText(agent).contains(Self.terminalKey))
        #expect(keysFileText(agent).contains("me@laptop"))
        await agent.stop()
    }

    @Test func aRefusedKeyIsNotInstalledAndTheAnswerGivesNothingAway() async throws {
        let (agent, identity, host, url, _) = try await pairForTerminalKey(approve: false)
        let answer = try await TerminalKeyClient.request(key: Self.terminalKey, host: host, urls: [url], identity: identity)
        #expect(answer.status == .denied)
        #expect(answer.username.isEmpty)
        #expect(answer.host_keys.isEmpty)
        #expect(keysFileText(agent).isEmpty)
        await agent.stop()
    }

    @Test func aStrangerIsNotAsked() async throws {
        let (agent, _, host, url, events) = try await pairForTerminalKey(approve: true)
        await #expect(throws: TerminalKeyClient.Failure.noAnswer) {
            _ = try await TerminalKeyClient.request(key: Self.terminalKey, host: host, urls: [url], identity: SoftwareIdentity(), timeoutMs: 3000)
        }
        #expect(!events.get().contains { if case .terminalKeyRequest = $0 { return true } else { return false } })
        #expect(keysFileText(agent).isEmpty)
        await agent.stop()
    }

    @Test func aKeyWithAnOptionOrACommentIsRefusedBeforeAnyoneIsAsked() throws {
        for bad in ["command=\"id\" " + Self.terminalKey, Self.terminalKey + " comment", Self.terminalKey + "\n" + Self.terminalKey, "ssh-rsa AAAAB3NzaC1yc2E="] {
            #expect(throws: (any Error).self, "\(bad)") { try TerminalKeyRequestPayload(ssh_public_key: bad).validate() }
        }
        try TerminalKeyRequestPayload(ssh_public_key: Self.terminalKey).validate()
    }
}
