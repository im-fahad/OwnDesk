import Foundation
import OwnDeskIdentity
import OwnDeskProtocol

/// A Mac or phone this device has paired with. One record serves both directions, because a single
/// pairing already exchanges both public keys: the host learns the controller's from PAIR_REQUEST,
/// and the controller learns the host's from PAIR_RESULT. What differs is permission, not knowledge.
public struct Peer: Codable, Sendable, Equatable, Identifiable {
    public var deviceId: String
    /// base64url X9.63 public key, 65 bytes.
    public var publicKey: String
    public var name: String
    public var type: DeviceType
    /// It may open sessions to us: we will host for it.
    public var mayControlUs: Bool
    /// We may open sessions to it: it will host for us.
    public var weMayControl: Bool
    /// Where we can reach it, most recently useful first.
    public var addresses: [String]
    public var rendezvousURL: String?
    public var pairedAt: Int64
    /// Last time it connected to us.
    public var lastSeen: Int64?
    /// Last time we connected to it.
    public var lastConnected: Int64?

    public var id: String { deviceId }
    public var fingerprint: String { (try? DeviceID.fingerprint(deviceId: deviceId)) ?? deviceId }
    public var publicKeyRaw: Data? { Base64URL.decode(publicKey) }

    public init(
        deviceId: String,
        publicKey: String,
        name: String,
        type: DeviceType,
        mayControlUs: Bool = false,
        weMayControl: Bool = false,
        addresses: [String] = [],
        rendezvousURL: String? = nil,
        pairedAt: Int64,
        lastSeen: Int64? = nil,
        lastConnected: Int64? = nil
    ) {
        self.deviceId = deviceId
        self.publicKey = publicKey
        self.name = name
        self.type = type
        self.mayControlUs = mayControlUs
        self.weMayControl = weMayControl
        self.addresses = addresses
        self.rendezvousURL = rendezvousURL
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
        self.lastConnected = lastConnected
    }


    /// Whether this peer can host at all. Only a Mac runs the hosting half: a phone has no
    /// signaling server and no address to reach, so it can never be on the other end of a session
    /// we open. Permission is a separate question, asked of `weMayControl`.
    public var canHost: Bool { type == .mac }

    /// A paired Mac can always be connected to from here: whether it lets us control it is its own
    /// decision, which it makes with its per-device switch and its hosting switch, and it tells us
    /// when it says no. So nothing on this side can switch that direction off. A phone only controls.
    public var normalized: Peer {
        guard type == .mac else { return self }
        var peer = self
        peer.weMayControl = true
        return peer
    }

    /// A peer we could actually open a session to: allowed, and able. Listing a phone as something
    /// to control leaves a row that can never come alive, which reads as a Mac that is offline.
    public var isHostForUs: Bool { weMayControl && canHost }
}
