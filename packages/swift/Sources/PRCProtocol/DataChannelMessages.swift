import Foundation

// Data channel protocol (spec sections 12.2 and 13). Validation mirrors packages/protocol/schemas/datachannel/*.json.

public enum ChannelLabel: String, Sendable, CaseIterable {
    case inputLossy = "input-lossy"
    case inputReliable = "input-reliable"
    case control

    /// RTCDataChannelInit values the controller uses when creating the channel.
    public var ordered: Bool { self != .inputLossy }
    public var maxRetransmits: Int? { self == .inputLossy ? 0 : nil }
}

public enum DataChannelType: String, Sendable, CaseIterable {
    case mouseMove = "mouse_move"
    case mouseMoveRel = "mouse_move_rel"
    case mouseDown = "mouse_down"
    case mouseUp = "mouse_up"
    case scroll
    case keyDown = "key_down"
    case keyUp = "key_up"
    case text
    case hello
    case displayInfo = "display_info"
    case captureState = "capture_state"
    case streamSettings = "stream_settings"
    case ping
    case pong
    case bye

    public var channel: ChannelLabel {
        switch self {
        case .mouseMove, .mouseMoveRel: .inputLossy
        case .mouseDown, .mouseUp, .scroll, .keyDown, .keyUp, .text: .inputReliable
        case .hello, .displayInfo, .captureState, .streamSettings, .ping, .pong, .bye: .control
        }
    }
}

public enum MouseButton: String, Sendable, CaseIterable { case left, right, middle }
public enum Modifier: String, Sendable, CaseIterable { case shift, control, alt, meta, capslock }
public enum ScrollPhase: String, Sendable, CaseIterable { case began, changed, ended, momentum }
public enum StreamPreference: String, Sendable, CaseIterable { case latency, quality }
/// Whether the host is really capturing. A motionless desktop and a dead capture look
/// identical on the wire, so the host says which one it is.
public enum CaptureState: String, Sendable, CaseIterable {
    case active
    case pausedLocked = "paused_locked"
    case pausedDisplayAsleep = "paused_display_asleep"
    case pausedError = "paused_error"

    public var isActive: Bool { self == .active }
}
public enum AppName: String, Sendable, CaseIterable {
    case macAgent = "mac-agent"
    case macController = "mac-controller"
    case androidController = "android-controller"
    case webHarness = "web-harness"
}

/// Host-side limits (spec section 21) and timing constants (sections 12.2 and 13.2).
public enum Limits {
    public static let mouseEventsPerSecond = 300
    public static let keyEventsPerSecond = 100
    public static let textEventsPerSecond = 50
    public static let malformedPerMinuteBeforeDisconnect = 100
    public static let mouseMoveCoalesceMs = 4
    public static let pingIntervalMs = 5000
    public static let missedPongsBeforeReconnect = 3
    public static let textMaxCodePoints = 256
    public static let maxRelativeDelta: Double = 4096
    public static let maxScrollDelta: Double = 10000
    public static let doubleClickMs = 500
    public static let doubleClickDistancePoints: Double = 5
    public static let idleTimeoutMinutes = 120
    public static let sessionLifetimeHours = 12
    public static let resumeWindowSeconds = 600
    public static let challengeTimeoutSeconds = 30
}

public enum DataChannelMessage: Sendable, Equatable {
    case mouseMove(displayId: String, x: Double, y: Double)
    case mouseMoveRel(dx: Double, dy: Double)
    case mouseDown(MouseButton)
    case mouseUp(MouseButton)
    /// Sign convention follows the browser WheelEvent: positive dy scrolls the content down.
    case scroll(dx: Double, dy: Double, precise: Bool, phase: ScrollPhase?)
    case keyDown(code: String, modifiers: [Modifier], repeat: Bool)
    case keyUp(code: String, modifiers: [Modifier])
    case text(String)
    case hello(versions: [Int], app: AppName, appVersion: String)
    case displayInfo(DisplayInfo)
    case captureState(CaptureState, detail: String?)
    case streamSettings(maxHeight: Int?, maxFps: Int?, prefer: StreamPreference?)
    case ping(nonce: UInt32)
    case pong(nonce: UInt32)
    case bye(SessionEndReason)

    public var type: DataChannelType {
        switch self {
        case .mouseMove: .mouseMove
        case .mouseMoveRel: .mouseMoveRel
        case .mouseDown: .mouseDown
        case .mouseUp: .mouseUp
        case .scroll: .scroll
        case .keyDown: .keyDown
        case .keyUp: .keyUp
        case .text: .text
        case .hello: .hello
        case .displayInfo: .displayInfo
        case .captureState: .captureState
        case .streamSettings: .streamSettings
        case .ping: .ping
        case .pong: .pong
        case .bye: .bye
        }
    }

    public var channel: ChannelLabel { type.channel }
}

/// One decoded data channel frame: the common header plus the message.
public struct DataChannelFrame: Sendable, Equatable {
    public var v: Int
    public var ts: Int64
    public var message: DataChannelMessage

    public init(v: Int = Envelope.protocolVersion, ts: Int64, message: DataChannelMessage) {
        self.v = v; self.ts = ts; self.message = message
    }
}

public enum DataChannelError: Error, Equatable, Sendable {
    case tooLarge
    case malformed
    case unknownType
    case invalid(String)
    case wrongChannel(expected: ChannelLabel)
}

/// JSON encoding and strict decoding of data channel frames. Never crashes on bad input.
public enum DataChannelCodec {
    public static let maxBytes = 4096

    public static func decode(_ data: Data, receivedOn: ChannelLabel? = nil) throws -> DataChannelFrame {
        guard data.count <= maxBytes else { throw DataChannelError.tooLarge }
        guard let any = try? JSONSerialization.jsonObject(with: data), let obj = any as? [String: Any] else { throw DataChannelError.malformed }
        guard let typeString = obj["type"] as? String, let type = DataChannelType(rawValue: typeString) else { throw DataChannelError.unknownType }
        let r = Reader(obj)
        let v = try r.int("v", 1...1000)
        let ts = try r.int64("ts", 0...Int64.max)
        let message: DataChannelMessage
        switch type {
        case .mouseMove:
            message = .mouseMove(displayId: try r.string("display_id", 1...64), x: try r.double("x", 0...1), y: try r.double("y", 0...1))
        case .mouseMoveRel:
            message = .mouseMoveRel(dx: try r.double("dx", -Limits.maxRelativeDelta...Limits.maxRelativeDelta), dy: try r.double("dy", -Limits.maxRelativeDelta...Limits.maxRelativeDelta))
        case .mouseDown:
            message = .mouseDown(try r.enumValue("button", MouseButton.self))
        case .mouseUp:
            message = .mouseUp(try r.enumValue("button", MouseButton.self))
        case .scroll:
            message = .scroll(
                dx: try r.double("dx", -Limits.maxScrollDelta...Limits.maxScrollDelta),
                dy: try r.double("dy", -Limits.maxScrollDelta...Limits.maxScrollDelta),
                precise: try r.bool("precise"),
                phase: try r.optionalEnum("phase", ScrollPhase.self))
        case .keyDown:
            message = .keyDown(code: try r.keyCode("code"), modifiers: try r.modifiers("modifiers"), repeat: try r.bool("repeat"))
        case .keyUp:
            message = .keyUp(code: try r.keyCode("code"), modifiers: try r.modifiers("modifiers"))
        case .text:
            let text = try r.string("text", 1...Int.max)
            guard text.unicodeScalars.count <= Limits.textMaxCodePoints else { throw DataChannelError.invalid("text") }
            message = .text(text)
        case .hello:
            let versions = try r.intArray("versions", count: 1...16, each: 1...1000)
            message = .hello(versions: versions, app: try r.enumValue("app", AppName.self), appVersion: try r.string("app_version", 1...32))
        case .displayInfo:
            let info = DisplayInfo(display_id: try r.string("display_id", 1...64), width_px: try r.int("width_px", 1...16384), height_px: try r.int("height_px", 1...16384), scale: try r.double("scale", 0.5...4))
            message = .displayInfo(info)
        case .captureState:
            message = .captureState(try r.enumValue("state", CaptureState.self), detail: try r.optionalString("detail", 0...200))
        case .streamSettings:
            message = .streamSettings(maxHeight: try r.optionalInt("max_height", 360...4320), maxFps: try r.optionalInt("max_fps", 5...120), prefer: try r.optionalEnum("prefer", StreamPreference.self))
        case .ping:
            message = .ping(nonce: UInt32(try r.int64("nonce", 0...Int64(UInt32.max))))
        case .pong:
            message = .pong(nonce: UInt32(try r.int64("nonce", 0...Int64(UInt32.max))))
        case .bye:
            message = .bye(try r.enumValue("reason", SessionEndReason.self))
        }
        if let receivedOn, receivedOn != type.channel { throw DataChannelError.wrongChannel(expected: type.channel) }
        return DataChannelFrame(v: v, ts: ts, message: message)
    }

    public static func encode(_ frame: DataChannelFrame) throws -> Data {
        var obj: [String: Any] = ["v": frame.v, "type": frame.message.type.rawValue, "ts": frame.ts]
        switch frame.message {
        case .mouseMove(let displayId, let x, let y):
            obj["display_id"] = displayId; obj["x"] = x; obj["y"] = y
        case .mouseMoveRel(let dx, let dy):
            obj["dx"] = dx; obj["dy"] = dy
        case .mouseDown(let b), .mouseUp(let b):
            obj["button"] = b.rawValue
        case .scroll(let dx, let dy, let precise, let phase):
            obj["dx"] = dx; obj["dy"] = dy; obj["precise"] = precise
            if let phase { obj["phase"] = phase.rawValue }
        case .keyDown(let code, let modifiers, let rep):
            obj["code"] = code; obj["modifiers"] = modifiers.map(\.rawValue); obj["repeat"] = rep
        case .keyUp(let code, let modifiers):
            obj["code"] = code; obj["modifiers"] = modifiers.map(\.rawValue)
        case .text(let text):
            obj["text"] = text
        case .hello(let versions, let app, let appVersion):
            obj["versions"] = versions; obj["app"] = app.rawValue; obj["app_version"] = appVersion
        case .displayInfo(let d):
            obj["display_id"] = d.display_id; obj["width_px"] = d.width_px; obj["height_px"] = d.height_px; obj["scale"] = d.scale
        case .captureState(let state, let detail):
            obj["state"] = state.rawValue
            if let detail { obj["detail"] = detail }
        case .streamSettings(let maxHeight, let maxFps, let prefer):
            if let maxHeight { obj["max_height"] = maxHeight }
            if let maxFps { obj["max_fps"] = maxFps }
            if let prefer { obj["prefer"] = prefer.rawValue }
        case .ping(let nonce), .pong(let nonce):
            obj["nonce"] = nonce
        case .bye(let reason):
            obj["reason"] = reason.rawValue
        }
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    public static func encode(_ message: DataChannelMessage, ts: Int64) throws -> Data {
        try encode(DataChannelFrame(ts: ts, message: message))
    }
}

/// Typed field access with the same constraints as the JSON Schemas.
private struct Reader {
    let obj: [String: Any]
    init(_ obj: [String: Any]) { self.obj = obj }

    private func number(_ key: String) throws -> NSNumber {
        guard let raw = obj[key] else { throw DataChannelError.invalid(key) }
        // JSONSerialization decodes true/false as NSNumber too. Reject them where a number is expected.
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw DataChannelError.invalid(key) }
        return n
    }

    func int(_ key: String, _ range: ClosedRange<Int>) throws -> Int {
        let n = try number(key)
        let d = n.doubleValue
        guard d == d.rounded(), let value = Int(exactly: d), range.contains(value) else { throw DataChannelError.invalid(key) }
        return value
    }

    func optionalInt(_ key: String, _ range: ClosedRange<Int>) throws -> Int? {
        obj[key] == nil ? nil : try int(key, range)
    }

    func int64(_ key: String, _ range: ClosedRange<Int64>) throws -> Int64 {
        let n = try number(key)
        let d = n.doubleValue
        guard d == d.rounded(), d.magnitude <= 9007199254740991, let value = Int64(exactly: d), range.contains(value) else { throw DataChannelError.invalid(key) }
        return value
    }

    func double(_ key: String, _ range: ClosedRange<Double>) throws -> Double {
        let d = try number(key).doubleValue
        guard d.isFinite, range.contains(d) else { throw DataChannelError.invalid(key) }
        return d
    }

    func bool(_ key: String) throws -> Bool {
        guard let raw = obj[key], let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw DataChannelError.invalid(key) }
        return n.boolValue
    }

    func string(_ key: String, _ length: ClosedRange<Int>) throws -> String {
        guard let s = obj[key] as? String, length.contains(s.count) else { throw DataChannelError.invalid(key) }
        return s
    }

    func optionalString(_ key: String, _ length: ClosedRange<Int>) throws -> String? {
        obj[key] == nil ? nil : try string(key, length)
    }

    func keyCode(_ key: String) throws -> String {
        let s = try string(key, 1...32)
        guard s.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) }) else { throw DataChannelError.invalid(key) }
        return s
    }

    func enumValue<E: RawRepresentable>(_ key: String, _: E.Type) throws -> E where E.RawValue == String {
        guard let s = obj[key] as? String, let v = E(rawValue: s) else { throw DataChannelError.invalid(key) }
        return v
    }

    func optionalEnum<E: RawRepresentable>(_ key: String, _ type: E.Type) throws -> E? where E.RawValue == String {
        obj[key] == nil ? nil : try enumValue(key, type)
    }

    func modifiers(_ key: String) throws -> [Modifier] {
        guard let arr = obj[key] as? [Any], arr.count <= 5 else { throw DataChannelError.invalid(key) }
        var out: [Modifier] = []
        for item in arr {
            guard let s = item as? String, let m = Modifier(rawValue: s), !out.contains(m) else { throw DataChannelError.invalid(key) }
            out.append(m)
        }
        return out
    }

    func intArray(_ key: String, count: ClosedRange<Int>, each: ClosedRange<Int>) throws -> [Int] {
        guard let arr = obj[key] as? [Any], count.contains(arr.count) else { throw DataChannelError.invalid(key) }
        return try arr.map { item in
            guard let n = item as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), let v = Int(exactly: n.doubleValue), each.contains(v) else { throw DataChannelError.invalid(key) }
            return v
        }
    }
}
