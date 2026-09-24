import Foundation

/// base64url without padding (RFC 4648 section 5), the only base64 flavour on the wire.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        guard isValid(string) else { return nil }
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }

    /// True when `string` uses only the base64url alphabet, has a decodable length,
    /// and, when `count` is given, has exactly that many characters.
    public static func isValid(_ string: String, count: Int? = nil) -> Bool {
        if let count, string.count != count { return false }
        if string.count % 4 == 1 { return false }
        return string.utf8.allSatisfy { c in
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
        }
    }
}

public enum Hex {
    public static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func isLowercaseHex(_ string: String, count: Int) -> Bool {
        string.utf8.count == count && string.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
