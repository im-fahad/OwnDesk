import Foundation
import PRCProtocol

/// Brings forward the two separate stores the split agent and controller apps kept, so an existing
/// pairing survives the merge instead of asking the user to pair again.
public enum PeerMigration {
    /// The agent's trusted-devices.json.
    private struct LegacyTrustedDevice: Decodable {
        var deviceId: String
        var publicKey: String
        var name: String
        var type: DeviceType
        var pairedAt: Int64
        var lastSeen: Int64?
    }

    /// The controller's hosts.json.
    private struct LegacyPairedHost: Decodable {
        var deviceId: String
        var publicKey: String
        var name: String
        var addresses: [String]
        var rendezvousURL: String?
        var pairedAt: Int64
        var lastConnected: Int64?
    }

    public struct Result: Sendable, Equatable {
        public var controllersImported: Int
        public var hostsImported: Int

        public init(controllersImported: Int = 0, hostsImported: Int = 0) {
            self.controllersImported = controllersImported
            self.hostsImported = hostsImported
        }

        public var didAnything: Bool { controllersImported > 0 || hostsImported > 0 }
    }

    /// Imports whichever legacy files exist. Safe to run repeatedly: `pair` widens permissions and
    /// never narrows them, so a second run changes nothing.
    @discardableResult
    public static func importLegacy(into store: PeerStore, agentDirectory: URL?, controllerDirectory: URL?, now: Int64) -> Result {
        var result = Result()
        let decoder = JSONDecoder()

        if let dir = agentDirectory,
           let data = try? Data(contentsOf: dir.appendingPathComponent("trusted-devices.json")),
           let devices = try? decoder.decode([LegacyTrustedDevice].self, from: data) {
            for d in devices {
                if (try? store.pair(deviceId: d.deviceId, publicKey: d.publicKey, name: d.name, type: d.type,
                                    mayControlUs: true, weMayControl: false, now: d.pairedAt)) != nil {
                    if let seen = d.lastSeen { store.touchSeen(d.deviceId, at: seen) }
                    result.controllersImported += 1
                }
            }
        }

        if let dir = controllerDirectory,
           let data = try? Data(contentsOf: dir.appendingPathComponent("hosts.json")),
           let hosts = try? decoder.decode([LegacyPairedHost].self, from: data) {
            for h in hosts {
                // The old controller store did not record a device type; a host was always a Mac.
                if (try? store.pair(deviceId: h.deviceId, publicKey: h.publicKey, name: h.name, type: .mac,
                                    mayControlUs: false, weMayControl: true,
                                    addresses: h.addresses, rendezvousURL: h.rendezvousURL, now: h.pairedAt)) != nil {
                    if let connected = h.lastConnected { store.touchConnected(h.deviceId, at: connected, address: nil) }
                    result.hostsImported += 1
                }
            }
        }
        return result
    }
}
