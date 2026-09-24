import Foundation
import Security

public enum CodeSigning {
    /// True when the running executable carries no certificate chain, meaning it is ad-hoc signed or
    /// unsigned. Such a signature changes on every build, so Keychain items it creates would prompt
    /// after each rebuild; callers use this to pick file-backed identity storage instead.
    public static var isAdHocSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return true }
        let certificates = dict[kSecCodeInfoCertificates as String] as? [Any] ?? []
        return certificates.isEmpty
    }
}
