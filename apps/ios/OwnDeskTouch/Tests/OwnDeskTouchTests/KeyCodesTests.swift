import Foundation
import OwnDeskProtocol
import OwnDeskTouch
import Testing

@Suite struct KeyCodesTests {
    /// The table in the protocol package is the source of truth, as it is for the Mac and Android.
    @Test func theHIDTableIsTheOneInTheProtocolPackage() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../../packages/protocol/keycodes/hid-to-w3c.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let codes = try #require(json?["codes"] as? [String: String])
        let fromFile = Dictionary(uniqueKeysWithValues: codes.map { (Int($0.key)!, $0.value) })
        #expect(fromFile == KeyCodes.hidToW3C)
    }

    /// A code the Mac does not know is dropped there as invalid, so a key that silently does nothing
    /// is what a stray entry would cost.
    @Test func everyKeyIsOneTheMacAccepts() {
        for (usage, code) in KeyCodes.hidToW3C {
            #expect(KeyCodeTable.w3cToMacOS[code] != nil, "HID \(usage) maps to \(code), which the host does not know")
        }
        #expect(KeyCodes.w3cCode(forHID: 0x04) == "KeyA")
        #expect(KeyCodes.w3cCode(forHID: 0x28) == "Enter")
        #expect(KeyCodes.w3cCode(forHID: 0x52) == "ArrowUp")
        #expect(KeyCodes.w3cCode(forHID: 0xE3) == "MetaLeft")
        #expect(KeyCodes.w3cCode(forHID: 0x46) == nil, "Print Screen has no Mac key")
    }

    @Test func charactersBecomeTheKeysThatTypeThem() {
        #expect(KeyCodes.key(for: "c")! == ("KeyC", false))
        #expect(KeyCodes.key(for: "C")! == ("KeyC", true))
        #expect(KeyCodes.key(for: "7")! == ("Digit7", false))
        #expect(KeyCodes.key(for: "?")! == ("Slash", true))
        #expect(KeyCodes.key(for: " ")! == ("Space", false))
        #expect(KeyCodes.key(for: "é") == nil, "a character with no US key is left to travel as text")
        for character in "abcXYZ019`-=[]\\;',./~!@#$%^&*()_+{}|:\"<>? " {
            let key = KeyCodes.key(for: character)
            #expect(key != nil, "no key for \(character)")
            if let key { #expect(KeyCodeTable.w3cToMacOS[key.code] != nil, "\(character) maps to \(key.code)") }
        }
    }

    @Test func longTextIsSplitWhereTheHostAllowsWithoutCuttingACharacter() {
        let long = String(repeating: "a", count: 600)
        let chunks = KeyCodes.textChunks(long)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.unicodeScalars.count <= Limits.textMaxCodePoints })
        #expect(chunks.joined() == long)

        // A family emoji is several code points; it has to land whole in one piece.
        let family = "👨‍👩‍👧"
        let mixed = String(repeating: "b", count: 254) + family
        let split = KeyCodes.textChunks(mixed)
        #expect(split.joined() == mixed)
        #expect(split.contains { $0.contains(family) })
        #expect(split.allSatisfy { $0.unicodeScalars.count <= Limits.textMaxCodePoints })
        #expect(KeyCodes.textChunks("").isEmpty)
    }
}
