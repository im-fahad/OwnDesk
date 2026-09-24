import Foundation
import OwnDeskIdentity
import OwnDeskProtocol

/// Tells a paired Mac that this device has removed the pairing, so that Mac removes it too and
/// neither side keeps a trust the other has dropped. It is best effort: a Mac that is off, asleep or
/// not hosting cannot be told, and the caller says so.
public enum UnpairClient {
    /// Sends UNPAIR to the first of `urls` that answers. Returns true once that Mac has taken it and
    /// closed the connection, which it does after removing this device.
    public static func send(to hostDeviceId: String, urls: [URL], identity: any SigningIdentity, timeoutMs: Int = 4000) async -> Bool {
        guard let url = await Endpoints.firstReachable(urls, timeoutMs: timeoutMs) else { return false }
        var sender = EnvelopeSender(identity: identity)
        guard let envelope = try? sender.build(.unpair(UnpairPayload()), to: hostDeviceId, session: ""),
              let bytes = try? envelope.serialized() else { return false }

        let client = SignalingClient(url: url)
        defer { client.close() }
        let opened = Waiter<Void>()
        let closed = Waiter<Void>()
        client.onEvent = { event in
            switch event {
            case .opened: opened.resolve(())
            case .closed(let reason):
                opened.fail(PairingError.connection(reason ?? "closed"))
                closed.resolve(())
            case .message: break
            }
        }
        client.connect()
        do { try await opened.value(timeoutMs: timeoutMs, onTimeout: PairingError.timeout) } catch { return false }
        client.send(String(decoding: bytes, as: UTF8.self))
        do {
            try await closed.value(timeoutMs: timeoutMs, onTimeout: PairingError.timeout)
            return true
        } catch {
            return false
        }
    }
}
