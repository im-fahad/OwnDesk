import Foundation
import OwnDeskAgentCore
import OwnDeskIdentity
import OwnDeskPeers
import OwnDeskProtocol
import Testing
@testable import OwnDeskControllerCore

/// An in-memory clipboard for the test host, so no test touches the real one.
final class MemoryClipboard: ClipboardBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    private var count = 0
    init(_ text: String?) { self.text = text; count = text == nil ? 0 : 1 }
    var changeCount: Int { lock.withLock { count } }
    func readText() -> String? { lock.withLock { text } }
    func write(_ newText: String) -> Int { lock.withLock { text = newText; count += 1; return count } }
    /// What someone at the host copying would do.
    func copy(_ newText: String) { lock.withLock { text = newText; count += 1 } }
}

/// Clipboard sync between a real host and a real session over WebRTC: each direction only when it
/// was switched on for it, the host's own direction only for a device it shares with, and nothing
/// echoed back. Part of the serialized end-to-end suite, since it pairs.
extension ControllerEndToEndTests {
    private func connectForClipboard(share: Bool) async throws
        -> (Agent, MemoryClipboard, SessionClient, Box<[String]>, Box<[Bool]>) {
        let clipboard = MemoryClipboard("copied on the host")
        let (agent, _) = try await E2E.startAgent(media: true, clipboard: clipboard)
        let address = "127.0.0.1:\(agent.port)"
        let identity = SoftwareIdentity()
        let outcome = try await PairingClient(identity: identity, deviceName: "Test Phone")
            .pair(qr: await agent.coordinator.openPairing(), preferredAddress: address)
        if share { try agent.peers.setShareClipboard(identity.deviceId, true) }

        let session = SessionClient(.init(identity: identity, host: outcome.host,
                                          config: ControllerConfig(deviceName: "Test Phone", dataDirectory: E2E.tempDir())))
        let received = Box<[String]>([])
        let shared = Box<[Bool]>([])
        let connected = Box(false)
        let stream = session.events
        Task {
            for await e in stream {
                switch e {
                case .clipboard(let text): received.update { $0.append(text) }
                case .clipboardShared(let on): shared.update { $0.append(on) }
                case .state(.connected): connected.update { $0 = true }
                default: break
                }
            }
        }
        await session.connect(url: Endpoints.url(for: address)!)
        try await E2E.waitUntil(timeoutMs: 20000, "connected") { connected.get() }
        try await Task.sleep(nanoseconds: 500_000_000)
        return (agent, clipboard, session, received, shared)
    }

    @Test func clipboardTravelsBothWaysOnceSwitchedOn() async throws {
        let (agent, clipboard, session, received, shared) = try await connectForClipboard(share: true)

        // Nothing moves before the person switches sync on.
        await session.sendClipboard("too early")
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(clipboard.readText() == "copied on the host")
        #expect(received.get().isEmpty)

        await session.setClipboardSync(true)
        try await E2E.waitUntil("the host says it shares") { shared.get().last == true }
        try await E2E.waitUntil("the host's clipboard arrives") { received.get() == ["copied on the host"] }

        await session.sendClipboard("copied on the phone, ünïcödé 👋")
        try await E2E.waitUntil("the phone's clipboard reaches the host") { clipboard.readText() == "copied on the phone, ünïcödé 👋" }
        // What the host was given is not sent back to the phone as a change.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(received.get() == ["copied on the host"])

        clipboard.copy("copied again on the host")
        try await E2E.waitUntil("a new copy on the host arrives") { received.get().last == "copied again on the host" }

        // Large text goes in one message.
        let big = String(repeating: "0123456789", count: 3000)
        await session.sendClipboard(big)
        try await E2E.waitUntil("30 000 characters arrive") { clipboard.readText() == big }

        // Switched off here: nothing more is sent either way.
        await session.setClipboardSync(false)
        try await Task.sleep(nanoseconds: 300_000_000)
        clipboard.copy("after it was switched off")
        await session.sendClipboard("also after")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(received.get().last == "copied again on the host")
        #expect(clipboard.readText() == "after it was switched off")
        await session.disconnect()
        await agent.stop()
    }

    @Test func aHostThatDoesNotShareStillTakesTheDevicesClipboard() async throws {
        let (agent, clipboard, session, received, shared) = try await connectForClipboard(share: false)
        await session.setClipboardSync(true)
        try await E2E.waitUntil("the host says it does not share") { shared.get().last == false }
        await session.sendClipboard("copied on the phone")
        try await E2E.waitUntil("the phone's clipboard reaches the host") { clipboard.readText() == "copied on the phone" }
        clipboard.copy("a password copied on the host")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(received.get().isEmpty, "the host's clipboard stays on the host")

        // Switched on at the host mid-session: the device is told, and gets it.
        let device = try #require(agent.peers.all.first { $0.name == "Test Phone" })
        try agent.peers.setShareClipboard(device.deviceId, true)
        await agent.coordinator.clipboardSharingChanged(for: device.deviceId)
        try await E2E.waitUntil("the host now shares") { shared.get().last == true }
        try await E2E.waitUntil("and its clipboard arrives") { received.get() == ["a password copied on the host"] }
        await session.disconnect()
        await agent.stop()
    }
}
