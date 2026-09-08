import Foundation
import PRCIdentity
import PRCProtocol

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

    /// Nothing is remembered about a peer that may do neither, so such a record is dropped.
    public var isTrustedEitherWay: Bool { mayControlUs || weMayControl }
}
