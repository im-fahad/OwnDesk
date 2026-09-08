import Foundation
import PRCIdentity
import PRCProtocol

/// The device's own list of paired peers, and the only authority on what each may do.
/// Kept in one file so a device that both hosts and controls has a single answer to "who is this",
/// rather than two stores that can disagree.
public final class PeerStore: @unchecked Sendable {
    private let fileURL: URL
    private var peers: [String: Peer] = [:]
    private let lock = NSLock()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fileURL = directory.appendingPathComponent("peers.json")
        if let data = try? Data(contentsOf: fileURL) {
            let list = try JSONDecoder().decode([Peer].self, from: data)
            peers = Dictionary(list.map { ($0.deviceId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    // MARK: Reading

    public var all: [Peer] {
        lock.lock(); defer { lock.unlock() }
        return peers.values.sorted { $0.pairedAt < $1.pairedAt }
    }

    /// Peers allowed to control this device.
    public var controllers: [Peer] { all.filter(\.mayControlUs) }

    /// Peers this device may control.
    public var hosts: [Peer] { all.filter(\.weMayControl) }

    public func peer(_ deviceId: String) -> Peer? {
        lock.lock(); defer { lock.unlock() }
        return peers[deviceId]
    }

    /// The peer record, but only when it is allowed to control us.
    public func controller(_ deviceId: String) -> Peer? {
        guard let p = peer(deviceId), p.mayControlUs else { return nil }
        return p
    }

    /// The peer record, but only when we are allowed to control it.
    public func host(_ deviceId: String) -> Peer? {
        guard let p = peer(deviceId), p.weMayControl else { return nil }
        return p
    }

    /// The key to verify envelopes from a device asking to control us. Returns nil once revoked, so
    /// verification fails closed without a separate check.
    public func controllerKey(_ deviceId: String) -> Data? {
        guard let p = peer(deviceId), p.mayControlUs else { return nil }
        return p.publicKeyRaw
    }

    /// The key to verify envelopes from a host we are connecting to.
    public func hostKey(_ deviceId: String) -> Data? {
        guard let p = peer(deviceId), p.weMayControl else { return nil }
        return p.publicKeyRaw
    }

    // MARK: Writing

    /// Records a pairing. Existing permissions are widened, never narrowed: pairing again should not
    /// silently revoke a direction the user already approved.
    @discardableResult
    public func pair(
        deviceId: String,
        publicKey: String,
        name: String,
        type: DeviceType,
        mayControlUs: Bool,
        weMayControl: Bool,
        addresses: [String] = [],
        rendezvousURL: String? = nil,
        now: Int64
    ) throws -> Peer {
        lock.lock(); defer { lock.unlock() }
        var peer = peers[deviceId] ?? Peer(deviceId: deviceId, publicKey: publicKey, name: name, type: type, pairedAt: now)
        peer.publicKey = publicKey
        peer.name = name
        peer.type = type
        peer.mayControlUs = peer.mayControlUs || mayControlUs
        peer.weMayControl = peer.weMayControl || weMayControl
        if let url = rendezvousURL { peer.rendezvousURL = url }
        for address in addresses.reversed() where !peer.addresses.contains(address) {
            peer.addresses.insert(address, at: 0)
        }
        peers[deviceId] = peer
        try save()
        return peer
    }

    public func setMayControlUs(_ deviceId: String, _ allowed: Bool) throws {
        try update(deviceId) { $0.mayControlUs = allowed }
    }

    public func setWeMayControl(_ deviceId: String, _ allowed: Bool) throws {
        try update(deviceId) { $0.weMayControl = allowed }
    }

    /// Forgets a peer entirely, in both directions.
    @discardableResult
    public func forget(_ deviceId: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard peers.removeValue(forKey: deviceId) != nil else { return false }
        try save()
        return true
    }

    public func touchSeen(_ deviceId: String, at time: Int64) {
        try? update(deviceId) { $0.lastSeen = time }
    }

    public func touchConnected(_ deviceId: String, at time: Int64, address: String?) {
        try? update(deviceId) { peer in
            peer.lastConnected = time
            if let address, !address.isEmpty {
                peer.addresses.removeAll { $0 == address }
                peer.addresses.insert(address, at: 0)
            }
        }
    }

    private func update(_ deviceId: String, _ change: (inout Peer) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard var peer = peers[deviceId] else { return }
        change(&peer)
        // A peer allowed to do nothing is not worth a signature check on every message.
        if peer.isTrustedEitherWay { peers[deviceId] = peer } else { peers.removeValue(forKey: deviceId) }
        try save()
    }

    /// Caller holds the lock.
    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(peers.values.sorted { $0.pairedAt < $1.pairedAt }).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
