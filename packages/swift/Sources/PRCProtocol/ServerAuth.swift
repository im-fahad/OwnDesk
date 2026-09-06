import Foundation
import PRCIdentity

/// Authentication of a device to the rendezvous server (spec section 11.1).
public enum ServerAuth {
    public static let context = "prc-server-auth-v1"
    public static let nonceBytes = 32
    public static let nonceTtlMs: Int64 = 60_000

    public static func signingInput(nonce: String, origin: String, deviceId: String) -> Data {
        Data("\(context)\n\(nonce)\n\(origin)\n\(deviceId)".utf8)
    }

    public static func sign(identity: any SigningIdentity, nonce: String, origin: String) throws -> String {
        Base64URL.encode(try identity.sign(signingInput(nonce: nonce, origin: origin, deviceId: identity.deviceId)))
    }

    public static func verify(publicKeyRaw: Data, nonce: String, origin: String, deviceId: String, signature: String) -> Bool {
        guard let sig = Base64URL.decode(signature) else { return false }
        return Verifier.verify(publicKeyRaw: publicKeyRaw, data: signingInput(nonce: nonce, origin: origin, deviceId: deviceId), signature: sig)
    }
}
