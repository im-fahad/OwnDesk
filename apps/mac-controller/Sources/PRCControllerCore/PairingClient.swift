import Foundation
import Network
import PRCIdentity
import PRCPeers
import PRCProtocol

public enum PairingError: Error, Equatable, Sendable {
    case invalidPayload(String)
    case expired
    case noReachableAddress
    case connection(String)
    case hostKeyMismatch
    case refused(PairRejectReason?)
    case timeout
}

/// Pairs this controller with a host from a pasted QR payload (spec section 7).
/// The host key received in PAIR_RESULT must hash to the key hash in the QR, so a fake host on the
/// LAN cannot collect the request.
public final class PairingClient: @unchecked Sendable {
    public struct Outcome: Sendable {
        public var host: Peer
        public var address: String
    }

    private let identity: any SigningIdentity
    private let deviceName: String

    public init(identity: any SigningIdentity, deviceName: String) {
        self.identity = identity
        self.deviceName = deviceName
    }

    public static func parse(_ text: String) throws -> QRPayload {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let qr = try? JSONDecoder().decode(QRPayload.self, from: data)
        else { throw PairingError.invalidPayload("not a pairing payload") }
        do { try qr.validate() } catch { throw PairingError.invalidPayload("\(error)") }
        return qr
    }

    /// Tries the given address first, then every address in the payload, until one accepts a connection.
    public func pair(qr: QRPayload, preferredAddress: String? = nil, timeoutMs: Int = 130_000) async throws -> Outcome {
        guard nowMs() < qr.expires_at else { throw PairingError.expired }
        var candidates = qr.addresses
        if let preferredAddress, !preferredAddress.isEmpty { candidates.insert(preferredAddress, at: 0) }
        var lastError: PairingError = .noReachableAddress
        for address in candidates {
            guard let url = Endpoints.url(for: address) else { continue }
            do {
                return try await attempt(qr: qr, url: url, address: address, timeoutMs: timeoutMs)
            } catch let error as PairingError {
                lastError = error
                if case .connection = error { continue }
                throw error
            }
        }
        throw lastError
    }

    private func attempt(qr: QRPayload, url: URL, address: String, timeoutMs: Int) async throws -> Outcome {
        let client = SignalingClient(url: url)
        defer { client.close() }
        var sender = EnvelopeSender(identity: identity)
        let identity = self.identity
        // Until PAIR_RESULT arrives we know only the host's key hash; accept the key it carries if it matches.
        let hostId = qr.host_device_id
        let receiver = ReceiverBox(EnvelopeReceiver(selfDeviceId: identity.deviceId, resolveKey: { from in
            from == hostId ? PairingClient.pendingHostKey.get() : nil
        }))

        let opened = Waiter<Void>()
        let result = Waiter<PairResultPayload>()
        client.onEvent = { event in
            switch event {
            case .opened: opened.resolve(())
            case .closed(let reason): opened.fail(PairingError.connection(reason ?? "closed")); result.fail(PairingError.connection(reason ?? "closed"))
            case .message(let text):
                guard let env = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)), env.type == SignalingType.pairResult.rawValue,
                      let payloadData = env.payloadData(), let payload = try? JSONDecoder().decode(PairResultPayload.self, from: payloadData),
                      let raw = Base64URL.decode(payload.host_public_key), (try? DeviceID.deviceId(publicKeyRaw: raw)) == hostId
                else { result.fail(PairingError.hostKeyMismatch); return }
                PairingClient.pendingHostKey.set(raw)
                switch receiver.receive(Data(text.utf8)) {
                case .accepted(_, .pairResult(let p), _): result.resolve(p)
                default: result.fail(PairingError.hostKeyMismatch)
                }
            }
        }
        client.connect()
        try await opened.value(timeoutMs: 5000, onTimeout: PairingError.connection("timeout"))

        guard let code = qr.pairingCodeBytes else { throw PairingError.invalidPayload("pairing_code") }
        let proof = Pairing.proof(pairingCode: code, pairingSessionId: qr.pairing_session_id, controllerDeviceId: identity.deviceId)
        let request = PairRequestPayload(public_key: identity.publicKeyB64, device_name: deviceName, device_type: .mac, pairing_session_id: qr.pairing_session_id, proof: proof)
        let env = try sender.build(.pairRequest(request), to: hostId, session: "")
        client.send(String(decoding: try env.serialized(), as: UTF8.self))

        let payload = try await result.value(timeoutMs: timeoutMs, onTimeout: PairingError.timeout)
        guard payload.approved else { throw PairingError.refused(payload.reason) }
        // Both sides now hold each other's key and both users compared fingerprints, so the record
        // covers both directions. Whether this Mac will actually host is gated by its own switch.
        let host = Peer(deviceId: hostId, publicKey: payload.host_public_key, name: payload.host_name, type: .mac,
                        mayControlUs: true, weMayControl: true, addresses: qr.addresses,
                        rendezvousURL: payload.rendezvous_url, pairedAt: nowMs())
        return Outcome(host: host, address: address)
    }

    /// The host key learned from the PAIR_RESULT under verification. One pairing at a time.
    static let pendingHostKey = Locked<Data?>(nil)
}

/// An EnvelopeReceiver usable from a callback closure.
final class ReceiverBox: @unchecked Sendable {
    private var receiver: EnvelopeReceiver
    private let lock = NSLock()
    init(_ receiver: EnvelopeReceiver) { self.receiver = receiver }
    func receive(_ data: Data) -> ReceiveResult { lock.lock(); defer { lock.unlock() }; return receiver.receive(data) }
}

final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
}

/// A one-shot value that can be awaited with a timeout.
final class Waiter<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?

    func resolve(_ value: T) { finish(.success(value)) }
    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ r: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: r)
    }

    func value(timeoutMs: Int, onTimeout: Error) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            lock.lock()
            if let result { lock.unlock(); c.resume(with: result); return }
            continuation = c
            lock.unlock()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                self?.fail(onTimeout)
            }
        }
    }
}
