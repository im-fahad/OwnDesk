import Foundation

/// W3C UI Events `KeyboardEvent.code` to macOS virtual key code. Loaded from the bundled copy of
/// packages/protocol/keycodes/w3c-to-macos.json; a test asserts the two files are identical.
public enum KeyCodeTable {
    private struct File: Decodable { let codes: [String: UInt16] }

    public static let w3cToMacOS: [String: UInt16] = {
        guard let url = Bundle.module.url(forResource: "w3c-to-macos", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [:] }
        return file.codes
    }()

    public static func macOSKeyCode(for w3cCode: String) -> UInt16? { w3cToMacOS[w3cCode] }
}
