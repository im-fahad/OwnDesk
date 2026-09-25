import Foundation
import OwnDeskIdentity
import OwnDeskPeers
import OwnDeskProtocol
import Testing

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("owndesk-peers-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let macBook = SoftwareIdentity()
private let mini = SoftwareIdentity()

@Suite struct PeerStoreTests {
    /// The bug this exists to prevent: pairing recorded both directions for every device, so a
    /// phone landed in "Macs you can control" with a dot that could never go green. A phone runs no
    /// hosting half and has no address to reach, so permission alone is not enough.
    @Test func aPhoneIsNeverSomethingWeCanControl() throws {
        let dir = tempDir()
        let store = try PeerStore(directory: dir)
        let phone = SoftwareIdentity()

        // Even with the permission set, which is what older records carry.
        try store.pair(deviceId: phone.deviceId, publicKey: phone.publicKeyB64, name: "Test Phone", type: .android,
                       mayControlUs: true, weMayControl: true, addresses: [], now: 100)

        let record = try #require(store.peer(phone.deviceId))
        #expect(record.canHost == false)
        #expect(record.isHostForUs == false)
        #expect(store.hosts.isEmpty)
        #expect(store.host(phone.deviceId) == nil)
        // Fails closed: a phone's key must never pass as a host's, since we would never open a
        // session to one.
        #expect(store.hostKey(phone.deviceId) == nil)

        // It can still control this Mac, which is the whole point of pairing it.
        #expect(store.controllerKey(phone.deviceId) == phone.publicKeyRaw)
        #expect(store.controllers.count == 1)
    }

    @Test func aMacWithPermissionIsStillAHost() throws {
        let dir = tempDir()
        let store = try PeerStore(directory: dir)
        try store.pair(deviceId: macBook.deviceId, publicKey: macBook.publicKeyB64, name: "MacBook", type: .mac,
                       mayControlUs: true, weMayControl: true, addresses: [], now: 100)
        let record = try #require(store.peer(macBook.deviceId))
        #expect(record.canHost)
        #expect(record.isHostForUs)
        #expect(store.hosts.count == 1)
    }

    @Test func permissionsGateTheKeyLookups() throws {
        let dir = tempDir()
        let store = try PeerStore(directory: dir)

        // One pairing, both directions: this is what the merged app records.
        try store.pair(deviceId: mini.deviceId, publicKey: mini.publicKeyB64, name: "Mac mini", type: .mac,
                       mayControlUs: true, weMayControl: true, addresses: ["192.168.1.20:47500"], now: 100)

        #expect(store.controllerKey(mini.deviceId) == mini.publicKeyRaw)
        #expect(store.hostKey(mini.deviceId) == mini.publicKeyRaw)
        #expect(store.controllers.count == 1 && store.hosts.count == 1)

        // Forgetting drops the record in both directions, and both key lookups fail closed.
        try store.forget(mini.deviceId)
        #expect(store.controllerKey(mini.deviceId) == nil)
        #expect(store.hostKey(mini.deviceId) == nil)
        #expect(store.all.isEmpty)
    }

    @Test func aPairedMacCanAlwaysBeConnectedToFromHere() throws {
        let dir = tempDir()
        // A record from when this side could switch off its own right to connect.
        let old = Peer(deviceId: mini.deviceId, publicKey: mini.publicKeyB64, name: "Mini", type: .mac,
                       mayControlUs: true, weMayControl: false, pairedAt: 1)
        try JSONEncoder().encode([old]).write(to: dir.appendingPathComponent("peers.json"))
        let store = try PeerStore(directory: dir)
        #expect(store.host(mini.deviceId) != nil, "whether it lets us in is that Mac's decision, not ours")
        let rewritten = try JSONDecoder().decode([Peer].self, from: Data(contentsOf: dir.appendingPathComponent("peers.json")))
        #expect(rewritten.first?.weMayControl == true)
    }

    @Test func switchingOffControlKeepsThePairing() throws {
        let store = try PeerStore(directory: tempDir())
        try store.pair(deviceId: mini.deviceId, publicKey: mini.publicKeyB64, name: "Mini", type: .mac,
                       mayControlUs: true, weMayControl: true, now: 1)
        try store.setMayControlUs(mini.deviceId, false)
        #expect(store.peer(mini.deviceId) != nil, "switched off, still paired")
        #expect(store.controllerKey(mini.deviceId) == nil)
        #expect(store.pairedKey(mini.deviceId) == mini.publicKeyRaw, "so it can still be told why")
        try store.setMayControlUs(mini.deviceId, true)
        #expect(store.controllerKey(mini.deviceId) == mini.publicKeyRaw, "and on again needs no new pairing")
    }

    /// An iPhone is paired the way the Android phone is: it controls, and never hosts.
    @Test func anIPhoneIsAPhoneToo() throws {
        let store = try PeerStore(directory: tempDir())
        let iPhone = SoftwareIdentity()
        try store.pair(deviceId: iPhone.deviceId, publicKey: iPhone.publicKeyB64, name: "iPhone", type: .ios,
                       mayControlUs: true, weMayControl: true, addresses: [], now: 1)
        let record = try #require(store.peer(iPhone.deviceId))
        #expect(record.canHost == false)
        #expect(store.hosts.isEmpty)
        #expect(store.hostKey(iPhone.deviceId) == nil)
        #expect(store.controllerKey(iPhone.deviceId) == iPhone.publicKeyRaw)
    }

    @Test func aPhoneOnlyEverControls() throws {
        let store = try PeerStore(directory: tempDir())
        try store.pair(deviceId: mini.deviceId, publicKey: mini.publicKeyB64, name: "Phone", type: .android,
                       mayControlUs: true, weMayControl: false, now: 1)
        #expect(store.controller(mini.deviceId) != nil)
        #expect(store.host(mini.deviceId) == nil, "a phone is never offered as something to control")
        try store.setMayControlUs(mini.deviceId, false)
        #expect(store.peer(mini.deviceId) != nil, "a phone switched off stays paired too")
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
        // A Mac that could control us can now also be connected to from here.
        #expect(controller.mayControlUs && controller.weMayControl)
        #expect(controller.lastSeen == 99 && controller.pairedAt == 10)

        let host = try #require(store.peer(mini.deviceId))
        // It could control that Mac; being controlled back is that Mac's to allow, here with the switch.
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
