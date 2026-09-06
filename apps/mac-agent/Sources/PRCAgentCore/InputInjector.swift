import CoreGraphics
import Foundation
import PRCProtocol

/// Receives validated input messages and applies them to the session.
public protocol InputSink: AnyObject, Sendable {
    func configure(display: MediaDisplay)
    /// Returns false when the message was dropped by a rate limit.
    @discardableResult
    func inject(_ message: DataChannelMessage, now: Int64) -> Bool
    func releaseAll()
}

struct RateLimiter {
    let perSecond: Int
    private var windowStart: Int64 = 0
    private var count = 0

    init(perSecond: Int) { self.perSecond = perSecond }

    mutating func allow(now: Int64) -> Bool {
        if now - windowStart >= 1000 { windowStart = now; count = 0 }
        count += 1
        return count <= perSecond
    }
}

/// Translates protocol input into Quartz events (spec section 14). Requires the Accessibility permission;
/// without it the system silently ignores posted events.
public final class InputInjector: InputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var display = MediaDisplay.main()
    private let source = CGEventSource(stateID: .hidSystemState)
    private var pressed: Set<MouseButton> = []
    private var lastClick: (button: MouseButton, time: Int64, point: CGPoint, count: Int64)?
    private var mouseLimiter = RateLimiter(perSecond: Limits.mouseEventsPerSecond)
    private var keyLimiter = RateLimiter(perSecond: Limits.keyEventsPerSecond)
    private var textLimiter = RateLimiter(perSecond: Limits.textEventsPerSecond)

    public init() {}

    public func configure(display: MediaDisplay) {
        lock.lock(); self.display = display; lock.unlock()
    }

    @discardableResult
    public func inject(_ message: DataChannelMessage, now: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch message {
        case .mouseMove(_, let x, let y):
            guard mouseLimiter.allow(now: now) else { return false }
            let b = display.pointBounds
            move(to: CGPoint(x: b.origin.x + x * b.width, y: b.origin.y + y * b.height))
        case .mouseMoveRel(let dx, let dy):
            guard mouseLimiter.allow(now: now) else { return false }
            let current = currentLocation()
            move(to: clamp(CGPoint(x: current.x + dx, y: current.y + dy)))
        case .mouseDown(let button):
            guard mouseLimiter.allow(now: now) else { return false }
            press(button, down: true, now: now)
        case .mouseUp(let button):
            guard mouseLimiter.allow(now: now) else { return false }
            press(button, down: false, now: now)
        case .scroll(let dx, let dy, let precise, let phase):
            guard mouseLimiter.allow(now: now) else { return false }
            scroll(dx: dx, dy: dy, precise: precise, phase: phase)
        case .keyDown(let code, let modifiers, let isRepeat):
            guard keyLimiter.allow(now: now) else { return false }
            key(code: code, modifiers: modifiers, down: true, isRepeat: isRepeat)
        case .keyUp(let code, let modifiers):
            guard keyLimiter.allow(now: now) else { return false }
            key(code: code, modifiers: modifiers, down: false, isRepeat: false)
        case .text(let text):
            guard textLimiter.allow(now: now) else { return false }
            type(text)
        case .hello, .displayInfo, .streamSettings, .ping, .pong, .bye:
            break
        }
        return true
    }

    /// Lift every held button so a dropped connection never leaves the mouse stuck down.
    public func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        for button in pressed { press(button, down: false, now: nowMs()) }
        pressed.removeAll()
    }

    // MARK: Mouse

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? display.pointBounds.origin
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        let b = display.pointBounds
        return CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
    }

    private func move(to point: CGPoint) {
        let type: CGEventType
        if pressed.contains(.left) { type = .leftMouseDragged }
        else if pressed.contains(.right) { type = .rightMouseDragged }
        else if pressed.contains(.middle) { type = .otherMouseDragged }
        else { type = .mouseMoved }
        let button: CGMouseButton = pressed.contains(.right) ? .right : pressed.contains(.middle) ? .center : .left
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }

    private func press(_ button: MouseButton, down: Bool, now: Int64) {
        let point = currentLocation()
        let cgButton: CGMouseButton
        let type: CGEventType
        switch button {
        case .left: cgButton = .left; type = down ? .leftMouseDown : .leftMouseUp
        case .right: cgButton = .right; type = down ? .rightMouseDown : .rightMouseUp
        case .middle: cgButton = .center; type = down ? .otherMouseDown : .otherMouseUp
        }
        var clickCount: Int64 = 1
        if down {
            if let last = lastClick, last.button == button, now - last.time <= Int64(Limits.doubleClickMs), hypot(last.point.x - point.x, last.point.y - point.y) <= Limits.doubleClickDistancePoints {
                clickCount = min(last.count + 1, 3)
            }
            lastClick = (button, now, point, clickCount)
            pressed.insert(button)
        } else {
            clickCount = lastClick?.button == button ? (lastClick?.count ?? 1) : 1
            pressed.remove(button)
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event.post(tap: .cghidEventTap)
    }

    private func scroll(dx: Double, dy: Double, precise: Bool, phase: ScrollPhase?) {
        // Protocol sign follows the browser WheelEvent (positive dy scrolls content down).
        // CGEvent wheel1 positive scrolls content up, so both axes flip.
        let units: CGScrollEventUnit = precise ? .pixel : .line
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2, wheel1: Int32(-dy.rounded()), wheel2: Int32(-dx.rounded()), wheel3: 0) else { return }
        if precise {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            if let phase {
                switch phase {
                case .began: event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
                case .changed: event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
                case .ended: event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
                case .momentum: event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
                }
            }
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    private func flags(for modifiers: [Modifier]) -> CGEventFlags {
        var f = CGEventFlags()
        for m in modifiers {
            switch m {
            case .shift: f.insert(.maskShift)
            case .control: f.insert(.maskControl)
            case .alt: f.insert(.maskAlternate)
            case .meta: f.insert(.maskCommand)
            case .capslock: f.insert(.maskAlphaShift)
            }
        }
        return f
    }

    private func key(code: String, modifiers: [Modifier], down: Bool, isRepeat: Bool) {
        guard let keyCode = KeyCodeTable.macOSKeyCode(for: code) else {
            Log.input.debug("unknown key code dropped")
            return
        }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = flags(for: modifiers)
        if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        event.post(tap: .cghidEventTap)
    }

    /// Unicode text insertion. Chunked so no event exceeds 20 UTF-16 units, and never split inside a scalar.
    private func type(_ text: String) {
        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            chunk.removeAll()
        }
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 20 { flush() }
            chunk.append(contentsOf: units)
        }
        flush()
    }
}
