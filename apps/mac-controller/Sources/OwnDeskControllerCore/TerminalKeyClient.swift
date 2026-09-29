import Foundation
import OwnDeskIdentity
import OwnDeskPeers
import OwnDeskProtocol

/// Asks a paired Mac to let this device's SSH key open terminals there (spec section 7.7), so nobody
/// has to paste a line into Terminal on the Mac. The Mac asks the person in front of it and installs
/// the key only when they allow it; this waits for that, up to the two minutes the Mac waits.
public enum TerminalKeyClient {
    public enum Failure: Error, Equatable, Sendable {
        /// None of the Mac's addresses answered: it is off, asleep, or not letting others in.
        case unreachable
        /// Connected, but no signed answer came back in time.
        case noAnswer
    }

    /// Sends TERMINAL_KEY_REQUEST to the first of `urls` that answers and returns the Mac's signed
    /// answer. Only an answer signed with the Mac's own paired key is taken, so a stranger on the
    /// network cannot hand this device a host key to trust.
    public static func request(key: String, host: Peer, urls: [URL], identity: any SigningIdentity,
                               timeoutMs: Int = 130_000) async throws -> TerminalKeyResultPayload {
        guard let url = await Endpoints.firstReachable(urls), let hostKey = host.publicKeyRaw else { throw Failure.unreachable }
        let hostId = host.deviceId
        let receiver = ReceiverBox(EnvelopeReceiver(selfDeviceId: identity.deviceId, resolveKey: { $0 == hostId ? hostKey : nil }))
        var sender = EnvelopeSender(identity: identity)
        let envelope = try sender.build(.terminalKeyRequest(TerminalKeyRequestPayload(ssh_public_key: key)), to: hostId, session: "")

        let client = SignalingClient(url: url)
        defer { client.close() }
        let opened = Waiter<Void>()
        let answer = Waiter<TerminalKeyResultPayload>()
        client.onEvent = { event in
            switch event {
            case .opened: opened.resolve(())
            case .closed(let reason):
                opened.fail(PairingError.connection(reason ?? "closed"))
                answer.fail(Failure.noAnswer)
            case .message(let text):
                if case .accepted(_, .terminalKeyResult(let result), _) = receiver.receive(Data(text.utf8)) {
                    answer.resolve(result)
                }
            }
        }
        client.connect()
        do { try await opened.value(timeoutMs: 5000, onTimeout: Failure.unreachable) } catch { throw Failure.unreachable }
        client.send(String(decoding: try envelope.serialized(), as: UTF8.self))
        return try await answer.value(timeoutMs: timeoutMs, onTimeout: Failure.noAnswer)
    }
}
