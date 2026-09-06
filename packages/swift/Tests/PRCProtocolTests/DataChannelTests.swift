import Foundation
import PRCProtocol
import Testing

@Suite struct DataChannelCodecTests {
    func decode(_ json: String, on channel: ChannelLabel? = nil) throws -> DataChannelFrame {
        try DataChannelCodec.decode(Data(json.utf8), receivedOn: channel)
    }

    @Test func validSamplesDecodeAndLandOnTheRightChannel() throws {
        let samples: [(String, DataChannelMessage, ChannelLabel)] = [
            ("{\"v\":1,\"type\":\"mouse_move\",\"ts\":1,\"display_id\":\"main\",\"x\":0.5,\"y\":1}", .mouseMove(displayId: "main", x: 0.5, y: 1), .inputLossy),
            ("{\"v\":1,\"type\":\"mouse_move_rel\",\"ts\":1,\"dx\":-3.5,\"dy\":12}", .mouseMoveRel(dx: -3.5, dy: 12), .inputLossy),
            ("{\"v\":1,\"type\":\"mouse_down\",\"ts\":1,\"button\":\"right\"}", .mouseDown(.right), .inputReliable),
            ("{\"v\":1,\"type\":\"mouse_up\",\"ts\":1,\"button\":\"left\"}", .mouseUp(.left), .inputReliable),
            ("{\"v\":1,\"type\":\"scroll\",\"ts\":1,\"dx\":0,\"dy\":-120,\"precise\":true,\"phase\":\"changed\"}", .scroll(dx: 0, dy: -120, precise: true, phase: .changed), .inputReliable),
            ("{\"v\":1,\"type\":\"scroll\",\"ts\":1,\"dx\":0,\"dy\":3,\"precise\":false}", .scroll(dx: 0, dy: 3, precise: false, phase: nil), .inputReliable),
            ("{\"v\":1,\"type\":\"key_down\",\"ts\":1,\"code\":\"KeyA\",\"modifiers\":[\"meta\",\"shift\"],\"repeat\":false}", .keyDown(code: "KeyA", modifiers: [.meta, .shift], repeat: false), .inputReliable),
            ("{\"v\":1,\"type\":\"key_up\",\"ts\":1,\"code\":\"MetaLeft\",\"modifiers\":[]}", .keyUp(code: "MetaLeft", modifiers: []), .inputReliable),
            ("{\"v\":1,\"type\":\"text\",\"ts\":1,\"text\":\"héllo 👋\"}", .text("héllo 👋"), .inputReliable),
            ("{\"v\":1,\"type\":\"hello\",\"ts\":0,\"versions\":[1],\"app\":\"mac-controller\",\"app_version\":\"0.1.0\"}", .hello(versions: [1], app: .macController, appVersion: "0.1.0"), .control),
            ("{\"v\":1,\"type\":\"display_info\",\"ts\":0,\"display_id\":\"main\",\"width_px\":1920,\"height_px\":1080,\"scale\":2}", .displayInfo(DisplayInfo(display_id: "main", width_px: 1920, height_px: 1080, scale: 2)), .control),
            ("{\"v\":1,\"type\":\"stream_settings\",\"ts\":0,\"max_fps\":30}", .streamSettings(maxHeight: nil, maxFps: 30, prefer: nil), .control),
            ("{\"v\":1,\"type\":\"ping\",\"ts\":0,\"nonce\":7}", .ping(nonce: 7), .control),
            ("{\"v\":1,\"type\":\"pong\",\"ts\":0,\"nonce\":4294967295}", .pong(nonce: 4294967295), .control),
            ("{\"v\":1,\"type\":\"bye\",\"ts\":0,\"reason\":\"idle_timeout\"}", .bye(.idleTimeout), .control),
        ]
        for (json, expected, channel) in samples {
            let frame = try decode(json, on: channel)
            #expect(frame.message == expected, "\(json)")
            #expect(frame.message.channel == channel)
            // Round trip through the encoder.
            let again = try DataChannelCodec.decode(try DataChannelCodec.encode(frame))
            #expect(again == frame, "\(json)")
        }
    }

    @Test func invalidInputsAreRejectedWithTheRightReason() {
        func rejects(_ json: String, _ expected: DataChannelError, _ label: String = "") {
            do {
                _ = try decode(json)
                Issue.record("expected \(expected) for \(json)")
            } catch let e as DataChannelError {
                switch (e, expected) {
                case (.invalid, .invalid): break
                default: #expect(e == expected, "\(json)")
                }
            } catch {
                Issue.record("unexpected error type \(error)")
            }
        }
        rejects(String(repeating: "x", count: 5000), .tooLarge)
        rejects("{", .malformed)
        rejects("\"str\"", .malformed)
        rejects("[]", .malformed)
        rejects("{\"v\":1,\"type\":\"execute_shell\",\"ts\":1,\"cmd\":\"rm -rf /\"}", .unknownType)
        rejects("{\"v\":1,\"type\":\"mouse_move\",\"ts\":1,\"display_id\":\"main\",\"x\":1.5,\"y\":0}", .invalid("x"))
        rejects("{\"v\":1,\"type\":\"mouse_move\",\"ts\":1,\"display_id\":\"main\",\"x\":-0.1,\"y\":0}", .invalid("x"))
        rejects("{\"v\":1,\"type\":\"mouse_move\",\"ts\":1,\"x\":0.5,\"y\":0.5}", .invalid("display_id"))
        rejects("{\"v\":1,\"type\":\"mouse_move_rel\",\"ts\":1,\"dx\":5000,\"dy\":0}", .invalid("dx"))
        rejects("{\"v\":1,\"type\":\"mouse_down\",\"ts\":1,\"button\":\"back\"}", .invalid("button"))
        rejects("{\"v\":1,\"type\":\"scroll\",\"ts\":1,\"dx\":0,\"dy\":20000,\"precise\":true}", .invalid("dy"))
        rejects("{\"v\":1,\"type\":\"scroll\",\"ts\":1,\"dx\":0,\"dy\":1,\"precise\":1}", .invalid("precise"))
        rejects("{\"v\":1,\"type\":\"key_down\",\"ts\":1,\"code\":\"Key A\",\"modifiers\":[],\"repeat\":false}", .invalid("code"))
        rejects("{\"v\":1,\"type\":\"key_down\",\"ts\":1,\"code\":\"KeyA\",\"modifiers\":[\"hyper\"],\"repeat\":false}", .invalid("modifiers"))
        rejects("{\"v\":1,\"type\":\"key_down\",\"ts\":1,\"code\":\"KeyA\",\"modifiers\":[\"shift\",\"shift\"],\"repeat\":false}", .invalid("modifiers"))
        rejects("{\"v\":1,\"type\":\"text\",\"ts\":1,\"text\":\"\"}", .invalid("text"))
        rejects("{\"v\":1,\"type\":\"text\",\"ts\":1,\"text\":\"\(String(repeating: "a", count: 257))\"}", .invalid("text"))
        rejects("{\"v\":1,\"type\":\"ping\",\"ts\":1}", .invalid("nonce"))
        rejects("{\"v\":1,\"type\":\"ping\",\"ts\":1,\"nonce\":4294967296}", .invalid("nonce"))
        rejects("{\"v\":1,\"type\":\"ping\",\"ts\":1.5,\"nonce\":1}", .invalid("ts"))
        rejects("{\"v\":true,\"type\":\"ping\",\"ts\":1,\"nonce\":1}", .invalid("v"))
        rejects("{\"v\":1,\"type\":\"bye\",\"ts\":1,\"reason\":\"because\"}", .invalid("reason"))
        rejects("{\"v\":1,\"type\":\"hello\",\"ts\":0,\"versions\":[],\"app\":\"mac-controller\",\"app_version\":\"1\"}", .invalid("versions"))
        rejects("{\"v\":1,\"type\":\"display_info\",\"ts\":0,\"display_id\":\"main\",\"width_px\":0,\"height_px\":1080,\"scale\":2}", .invalid("width_px"))
    }

    @Test func textLimitCountsCodePoints() throws {
        let emoji256 = String(repeating: "👋", count: 256)
        _ = try decode("{\"v\":1,\"type\":\"text\",\"ts\":1,\"text\":\"\(emoji256)\"}")
        #expect(throws: DataChannelError.invalid("text")) { try decode("{\"v\":1,\"type\":\"text\",\"ts\":1,\"text\":\"\(emoji256)a\"}") }
    }

    @Test func wrongChannelIsRejected() throws {
        #expect(throws: DataChannelError.wrongChannel(expected: .inputReliable)) {
            try decode("{\"v\":1,\"type\":\"key_down\",\"ts\":1,\"code\":\"KeyA\",\"modifiers\":[],\"repeat\":false}", on: .inputLossy)
        }
        _ = try decode("{\"v\":1,\"type\":\"mouse_move\",\"ts\":1,\"display_id\":\"main\",\"x\":0,\"y\":0}", on: .inputLossy)
    }

    @Test func channelConfigMatchesSpec() {
        #expect(ChannelLabel.inputLossy.ordered == false && ChannelLabel.inputLossy.maxRetransmits == 0)
        #expect(ChannelLabel.inputReliable.ordered == true && ChannelLabel.inputReliable.maxRetransmits == nil)
        #expect(ChannelLabel.control.ordered == true)
    }
}

@Suite struct KeyCodeTableTests {
    @Test func bundledTableMatchesProtocolPackage() throws {
        struct File: Decodable { let codes: [String: UInt16] }
        let source = Vectors.directory.deletingLastPathComponent().appendingPathComponent("keycodes/w3c-to-macos.json")
        let expected = try JSONDecoder().decode(File.self, from: Data(contentsOf: source)).codes
        #expect(KeyCodeTable.w3cToMacOS == expected)
        #expect(KeyCodeTable.w3cToMacOS.count > 100)
        #expect(KeyCodeTable.macOSKeyCode(for: "KeyA") == 0)
        #expect(KeyCodeTable.macOSKeyCode(for: "Enter") == 36)
        #expect(KeyCodeTable.macOSKeyCode(for: "ArrowUp") == 126)
        #expect(KeyCodeTable.macOSKeyCode(for: "Nope") == nil)
    }
}
