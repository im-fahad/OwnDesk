import Foundation
import PRCIdentity
import PRCPeers
import PRCProtocol
import Testing

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("prc-peers-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let macBook = SoftwareIdentity()
private let mini = SoftwareIdentity()

@Suite struct PeerStoreTests {
    @Test func permissionsGateTheKeyLookups() throws {
        let dir = tempDir()
        let store = try PeerStore(directory: dir)

        // One pairing, both directions: this is what the merged app records.
        try store.pair(deviceId: mini.deviceId, publicKey: mini.publicKeyB64, name: "Mac mini", type: .mac,
                       mayControlUs: true, weMayControl: true, addresses: ["192.168.1.20:47500"], now: 100)

        #expect(store.controllerKey(mini.deviceId) == mini.publicKeyRaw)
        #expect(store.hostKey(mini.deviceId) == mini.publicKeyRaw)
        #expect(store.controllers.count == 1 && store.hosts.count == 1)

        // Revoking one direction leaves the other, and the key lookup for the revoked side fails
        // closed rather than needing a separate check at the call site.
        try store.setMayControlUs(mini.deviceId, false)
        #expect(store.controllerKey(mini.deviceId) == nil)
        #expect(store.hostKey(mini.deviceId) == mini.publicKeyRaw)
        #expect(store.controllers.isEmpty && store.hosts.count == 1)

        // Revoking the last direction drops the record entirely.
        try store.setWeMayControl(mini.deviceId, false)
        #expect(store.peer(mini.deviceId) == nil)
        #expect(store.all.isEmpty)
    }

    @Test func pairingWidensButNeverNarrows() throws {
        let store = try PeerStore(directory: tempDir())
        try store.pair(deviceId: mini.deviceId, publicKey: mini.publicKeyB64, name: "Mini", type: .mac,
                       mayControlUs: true, weMayControl: false, now: 1)
        // Pairing again in the other direction must not revoke what the user already approved.
        try store.pair(deviceId: mini.deviceId, publicKey: mini.publicKeyB64, name: "Mini renamed", type: .mac,
                       mayControlUs: false, weMayControl: true, now: 2)
        let peer = try #require(store.peer(mini.deviceId))
        #expect(peer.mayControlUs && peer.weMayControl)
        #expect(peer.name == "Mini renamed")
        #expect(peer.pairedAt == 1, "the original pairing time survives")
    }

    @Test func addressesAndTimestampsPersist() throws {
        let dir = tempDir()
        let store = try PeerStore(directory: dir)
        try store.pair(deviceId: mini.deviceId, publicKey: mini.publicKeyB64, name: "Mini", type: .mac,
                       mayControlUs: true, weMayControl: true, addresses: ["10.0.0.2:47500"], now: 1)
        store.touchSeen(mini.deviceId, at: 50)
        store.touchConnected(mini.deviceId, at: 60, address: "100.80.1.1:47500")

        let reloaded = try PeerStore(directory: dir)
        let peer = try #require(reloaded.peer(mini.deviceId))
        #expect(peer.lastSeen == 50 && peer.lastConnected == 60)
        #expect(peer.addresses.first == "100.80.1.1:47500", "the address that worked comes first")
        #expect(peer.addresses.contains("10.0.0.2:47500"))
        #expect(peer.fingerprint == (try DeviceID.fingerprint(deviceId: mini.deviceId)))

        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("peers.json").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }
}

@Suite struct PeerMigrationTests {
    /// Writes the two files the split apps used to keep.
    private func writeLegacy(agent: URL?, controller: URL?) throws {
        if let agent {
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            let json = """
            [{"deviceId":"\(macBook.deviceId)","publicKey":"\(macBook.publicKeyB64)","name":"MacBook Pro","type":"mac","pairedAt":10,"lastSeen":99}]
            """
            try json.write(to: agent.appendingPathComponent("trusted-devices.json"), atomically: true, encoding: .utf8)
        }
        if let controller {
            try FileManager.default.createDirectory(at: controller, withIntermediateDirectories: true)
            let json = """
            [{"deviceId":"\(mini.deviceId)","publicKey":"\(mini.publicKeyB64)","name":"Mac mini","addresses":["192.168.1.20:47500"],"pairedAt":20,"lastConnected":88}]
            """
            try json.write(to: controller.appendingPathComponent("hosts.json"), atomically: true, encoding: .utf8)
        }
    }

    @Test func bothLegacyStoresSurviveTheMerge() throws {
        let agentDir = tempDir(), controllerDir = tempDir(), newDir = tempDir()
        try writeLegacy(agent: agentDir, controller: controllerDir)
        let store = try PeerStore(directory: newDir)

        let result = PeerMigration.importLegacy(into: store, agentDirectory: agentDir, controllerDirectory: controllerDir, now: 1000)
        #expect(result == .init(controllersImported: 1, hostsImported: 1))

        let controller = try #require(store.peer(macBook.deviceId))
        #expect(controller.mayControlUs && !controller.weMayControl)
        #expect(controller.lastSeen == 99 && controller.pairedAt == 10)

        let host = try #require(store.peer(mini.deviceId))
        #expect(host.weMayControl && !host.mayControlUs)
        #expect(host.addresses == ["192.168.1.20:47500"] && host.lastConnected == 88)
        #expect(host.type == .mac)
    }

    @Test func importingTwiceChangesNothing() throws {
        let agentDir = tempDir(), controllerDir = tempDir(), newDir = tempDir()
        try writeLegacy(agent: agentDir, controller: controllerDir)
        let store = try PeerStore(directory: newDir)
        PeerMigration.importLegacy(into: store, agentDirectory: agentDir, controllerDirectory: controllerDir, now: 1000)
        let first = store.all
        PeerMigration.importLegacy(into: store, agentDirectory: agentDir, controllerDirectory: controllerDir, now: 2000)
        #expect(store.all == first, "migration is safe to run on every launch")
    }

    @Test func missingLegacyFilesAreNotAnError() throws {
        let store = try PeerStore(directory: tempDir())
        let result = PeerMigration.importLegacy(into: store, agentDirectory: tempDir(), controllerDirectory: nil, now: 1)
        #expect(!result.didAnything)
        #expect(store.all.isEmpty)
    }
}
