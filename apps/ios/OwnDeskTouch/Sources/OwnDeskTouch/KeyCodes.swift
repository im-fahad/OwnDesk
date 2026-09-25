import Foundation
import OwnDeskProtocol

/// Keys as the wire names them: W3C `KeyboardEvent.code`, which the Mac turns into its own key codes.
public enum KeyCodes {
    /// USB HID keyboard usages to W3C codes. A hardware keyboard on an iPhone or iPad reports the
    /// HID usage as `UIKey.keyCode`, so this is all the translation it needs. The table is
    /// packages/protocol/keycodes/hid-to-w3c.json; a test keeps the two identical, and every code in it
    /// is one the Mac accepts.
    public static let hidToW3C: [Int: String] = [
        4: "KeyA",
        5: "KeyB",
        6: "KeyC",
        7: "KeyD",
        8: "KeyE",
        9: "KeyF",
        10: "KeyG",
        11: "KeyH",
        12: "KeyI",
        13: "KeyJ",
        14: "KeyK",
        15: "KeyL",
        16: "KeyM",
        17: "KeyN",
        18: "KeyO",
        19: "KeyP",
        20: "KeyQ",
        21: "KeyR",
        22: "KeyS",
        23: "KeyT",
        24: "KeyU",
        25: "KeyV",
        26: "KeyW",
        27: "KeyX",
        28: "KeyY",
        29: "KeyZ",
        30: "Digit1",
        31: "Digit2",
        32: "Digit3",
        33: "Digit4",
        34: "Digit5",
        35: "Digit6",
        36: "Digit7",
        37: "Digit8",
        38: "Digit9",
        39: "Digit0",
        40: "Enter",
        41: "Escape",
        42: "Backspace",
        43: "Tab",
        44: "Space",
        45: "Minus",
        46: "Equal",
        47: "BracketLeft",
        48: "BracketRight",
        49: "Backslash",
        51: "Semicolon",
        52: "Quote",
        53: "Backquote",
        54: "Comma",
        55: "Period",
        56: "Slash",
        57: "CapsLock",
        58: "F1",
        59: "F2",
        60: "F3",
        61: "F4",
        62: "F5",
        63: "F6",
        64: "F7",
        65: "F8",
        66: "F9",
        67: "F10",
        68: "F11",
        69: "F12",
        73: "Insert",
        74: "Home",
        75: "PageUp",
        76: "Delete",
        77: "End",
        78: "PageDown",
        79: "ArrowRight",
        80: "ArrowLeft",
        81: "ArrowDown",
        82: "ArrowUp",
        83: "NumLock",
        84: "NumpadDivide",
        85: "NumpadMultiply",
        86: "NumpadSubtract",
        87: "NumpadAdd",
        88: "NumpadEnter",
        89: "Numpad1",
        90: "Numpad2",
        91: "Numpad3",
        92: "Numpad4",
        93: "Numpad5",
        94: "Numpad6",
        95: "Numpad7",
        96: "Numpad8",
        97: "Numpad9",
        98: "Numpad0",
        99: "NumpadDecimal",
        100: "IntlBackslash",
        101: "ContextMenu",
        103: "NumpadEqual",
        104: "F13",
        105: "F14",
        106: "F15",
        107: "F16",
        108: "F17",
        109: "F18",
        110: "F19",
        111: "F20",
        117: "Help",
        127: "AudioVolumeMute",
        128: "AudioVolumeUp",
        129: "AudioVolumeDown",
        133: "NumpadComma",
        135: "IntlRo",
        137: "IntlYen",
        144: "Lang1",
        145: "Lang2",
        224: "ControlLeft",
        225: "ShiftLeft",
        226: "AltLeft",
        227: "MetaLeft",
        228: "ControlRight",
        229: "ShiftRight",
        230: "AltRight",
        231: "MetaRight",
    ]

    public static func w3cCode(forHID usage: Int) -> String? { hidToW3C[usage] }

    /// The key that types `character` on a US layout, and whether Shift is part of it.
    ///
    /// Only needed when a modifier from the key bar is held: typed on its own a character travels as
    /// text, which is right on any layout, but ⌘C has to be a key press, since a Command-held "c" is
    /// not text. Shortcuts are named by their US key on a Mac too, so this is the one layout to know.
    public static func key(for character: Character) -> (code: String, shift: Bool)? {
        if let ascii = character.asciiValue {
            switch ascii {
            case UInt8(ascii: "a")...UInt8(ascii: "z"):
                return ("Key" + String(character).uppercased(), false)
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                return ("Key" + String(character), true)
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                return ("Digit" + String(character), false)
            default:
                break
            }
        }
        return punctuation[character]
    }

    private static let punctuation: [Character: (code: String, shift: Bool)] = [
        " ": ("Space", false), "\n": ("Enter", false), "\t": ("Tab", false),
        "-": ("Minus", false), "_": ("Minus", true),
        "=": ("Equal", false), "+": ("Equal", true),
        "[": ("BracketLeft", false), "{": ("BracketLeft", true),
        "]": ("BracketRight", false), "}": ("BracketRight", true),
        "\\": ("Backslash", false), "|": ("Backslash", true),
        ";": ("Semicolon", false), ":": ("Semicolon", true),
        "'": ("Quote", false), "\"": ("Quote", true),
        "`": ("Backquote", false), "~": ("Backquote", true),
        ",": ("Comma", false), "<": ("Comma", true),
        ".": ("Period", false), ">": ("Period", true),
        "/": ("Slash", false), "?": ("Slash", true),
        "!": ("Digit1", true), "@": ("Digit2", true), "#": ("Digit3", true), "$": ("Digit4", true),
        "%": ("Digit5", true), "^": ("Digit6", true), "&": ("Digit7", true), "*": ("Digit8", true),
        "(": ("Digit9", true), ")": ("Digit0", true),
    ]

    /// Splits text into pieces the host accepts: a `text` message carries at most
    /// `Limits.textMaxCodePoints` code points, and a paste can be far longer. Splits fall between
    /// characters, never inside one, so an emoji is never cut in half.
    public static func textChunks(_ text: String, limit: Int = Limits.textMaxCodePoints) -> [String] {
        var chunks: [String] = []
        var current = ""
        var count = 0
        for character in text {
            let size = character.unicodeScalars.count
            if count + size > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
                count = 0
            }
            current.append(character)
            count += size
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
