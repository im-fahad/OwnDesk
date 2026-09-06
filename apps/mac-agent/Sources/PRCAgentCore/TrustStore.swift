import Foundation
import PRCIdentity
import PRCProtocol

public struct TrustedDevice: Codable, Sendable, Equatable {
    public var deviceId: String
    /// base64url X9.63 public key.
    public var publicKey: String
    public var name: String
    public var type: DeviceType
    public var pairedAt: Int64
    public var lastSeen: Int64?

    public var fingerprint: String { (try? DeviceID.fingerprint(deviceId: deviceId)) ?? deviceId }
    public var publicKeyRaw: Data? { Base64URL.decode(publicKey) }
}

/// The Mac Mini's list of trusted controllers. The only authority for trust in the system.
/// Stored as JSON in the agent's data directory with owner-only permissions. Contains no secrets.
public final class TrustStore: @unchecked Sendable {
    private let fileURL: URL
    private var devices: [String: TrustedDevice] = [:]
    private let lock = NSLock()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fileURL = directory.appendingPathComponent("trusted-devices.json")
        if let data = try? Data(contentsOf: fileURL) {
            let list = try JSONDecoder().decode([TrustedDevice].self, from: data)
            devices = Dictionary(uniqueKeysWithValues: list.map { ($0.deviceId, $0) })
        }
    }

    public var all: [TrustedDevice] {
        lock.lock(); defer { lock.unlock() }
        return devices.values.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func device(_ deviceId: String) -> TrustedDevice? {
        lock.lock(); defer { lock.unlock() }
        return devices[deviceId]
    }

    public func publicKey(for deviceId: String) -> Data? {
        device(deviceId)?.publicKeyRaw
    }

    public func add(_ device: TrustedDevice) throws {
        lock.lock(); defer { lock.unlock() }
        devices[device.deviceId] = device
        try save()
    }

    @discardableResult
    public func revoke(_ deviceId: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard devices.removeValue(forKey: deviceId) != nil else { return false }
        try save()
        return true
    }

    public func touch(_ deviceId: String, at time: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard var d = devices[deviceId] else { return }
        d.lastSeen = time
        devices[deviceId] = d
        try? save()
    }

    /// Caller holds the lock.
    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Array(devices.values))
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
