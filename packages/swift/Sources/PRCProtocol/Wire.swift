import Foundation
import PRCIdentity

public enum PayloadError: Error, Equatable, Sendable {
    case invalid(String)
}

/// Field-level checks mirroring packages/protocol/schemas/common.json.
public enum Wire {
    public static func isBytes16(_ s: String) -> Bool { Base64URL.isValid(s, count: 22) }
    public static func isBytes32(_ s: String) -> Bool { Base64URL.isValid(s, count: 43) }
    public static func isSignature(_ s: String) -> Bool { Base64URL.isValid(s, count: 86) }
    public static func isPublicKey(_ s: String) -> Bool { Base64URL.isValid(s, count: 87) }
    public static func isDeviceName(_ s: String) -> Bool { (1...64).contains(s.count) }
    public static func isWsUrl(_ s: String) -> Bool {
        (s.hasPrefix("ws://") || s.hasPrefix("wss://")) && s.count <= 512 && !s.contains(where: { $0.isWhitespace })
    }

    static func require(_ ok: Bool, _ field: String) throws {
        if !ok { throw PayloadError.invalid(field) }
    }
}
