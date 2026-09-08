import Foundation
import PRCIdentity
import PRCProtocol

/// A host this controller has paired with. The host's key is what every session is verified against.
public struct PairedHost: Codable, Sendable, Equatable, Identifiable {
    public var deviceId: String
    public var publicKey: String
    public var name: String
    public var addresses: [String]
    public var rendezvousURL: String?
    public var pairedAt: Int64
    public var lastConnected: Int64?

    public var id: String { deviceId }
    public var fingerprint: String { (try? DeviceID.fingerprint(deviceId: deviceId)) ?? deviceId }
    public var publicKeyRaw: Data? { Base64URL.decode(publicKey) }

    public init(deviceId: String, publicKey: String, name: String, addresses: [String], rendezvousURL: String?, pairedAt: Int64, lastConnected: Int64? = nil) {
        self.deviceId = deviceId; self.publicKey = publicKey; self.name = name; self.addresses = addresses
        self.rendezvousURL = rendezvousURL; self.pairedAt = pairedAt; self.lastConnected = lastConnected
    }
}

public final class HostStore: @unchecked Sendable {
    private let fileURL: URL
    private var hosts: [String: PairedHost] = [:]
    private let lock = NSLock()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fileURL = directory.appendingPathComponent("hosts.json")
        if let data = try? Data(contentsOf: fileURL) {
            let list = try JSONDecoder().decode([PairedHost].self, from: data)
            hosts = Dictionary(uniqueKeysWithValues: list.map { ($0.deviceId, $0) })
        }
    }

    public var all: [PairedHost] {
        lock.lock(); defer { lock.unlock() }
        return hosts.values.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func host(_ deviceId: String) -> PairedHost? {
        lock.lock(); defer { lock.unlock() }
        return hosts[deviceId]
    }

    public func save(_ host: PairedHost) throws {
        lock.lock(); defer { lock.unlock() }
        hosts[host.deviceId] = host
        try persist()
    }

    @discardableResult
    public func forget(_ deviceId: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard hosts.removeValue(forKey: deviceId) != nil else { return false }
        try persist()
        return true
    }

    public func touch(_ deviceId: String, at time: Int64, address: String?) {
        lock.lock(); defer { lock.unlock() }
        guard var h = hosts[deviceId] else { return }
        h.lastConnected = time
        if let address, !h.addresses.contains(address) { h.addresses.insert(address, at: 0) }
        hosts[deviceId] = h
        try? persist()
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Array(hosts.values)).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
