import AppKit
import Foundation
import PRCProtocol

/// Maps points in the video view to normalized host coordinates, honouring aspect-fit letterboxing.
public struct VideoGeometry: Sendable, Equatable {
    public var viewSize: CGSize
    public var videoSize: CGSize

    public init(viewSize: CGSize, videoSize: CGSize) {
        self.viewSize = viewSize
        self.videoSize = videoSize
    }

    /// Where the video pixels actually are inside the view, in the view's (flipped, top-left origin) coordinates.
    public var contentRect: CGRect {
        guard viewSize.width > 0, viewSize.height > 0, videoSize.width > 0, videoSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
        let w = videoSize.width * scale, h = videoSize.height * scale
        return CGRect(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2, width: w, height: h)
    }

    /// Normalized 0...1 coordinates, or nil when the point is in the letterbox.
    public func normalize(_ point: CGPoint) -> (x: Double, y: Double)? {
        let r = contentRect
        guard r.width > 0, r.height > 0, r.contains(point) || r.insetBy(dx: -0.5, dy: -0.5).contains(point) else { return nil }
        let x = min(max((point.x - r.minX) / r.width, 0), 1)
        let y = min(max((point.y - r.minY) / r.height, 0), 1)
        return (Double(x), Double(y))
    }
}

/// macOS virtual key codes to W3C codes, inverted from the shared table. A few virtual keys map to
/// two W3C names; the preferred one is listed here.
public enum KeyMap {
    private static let preferred: Set<String> = ["Insert"]

    public static let macOSToW3C: [UInt16: String] = {
        var out: [UInt16: String] = [:]
        for (name, code) in KeyCodeTable.w3cToMacOS {
            if let existing = out[code] {
                if preferred.contains(name) || (!preferred.contains(existing) && name < existing) { out[code] = name }
            } else {
                out[code] = name
            }
        }
        return out
    }()

    public static func w3cCode(for keyCode: UInt16) -> String? { macOSToW3C[keyCode] }

    public static func modifiers(from flags: NSEvent.ModifierFlags) -> [Modifier] {
        var out: [Modifier] = []
        if flags.contains(.shift) { out.append(.shift) }
        if flags.contains(.control) { out.append(.control) }
        if flags.contains(.option) { out.append(.alt) }
        if flags.contains(.command) { out.append(.meta) }
        if flags.contains(.capsLock) { out.append(.capslock) }
        return out
    }

    /// The modifier bit a physical modifier key toggles, so flagsChanged can be turned into key up and down.
    public static func modifierFlag(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 56, 60: return .shift
        case 59, 62: return .control
        case 58, 61: return .option
        case 55, 54: return .command
        case 57: return .capsLock
        case 63: return .function
        default: return nil
        }
    }
}

public enum MouseMap {
    public static func button(for event: NSEvent) -> MouseButton {
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return .right
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged: return .middle
        default: return event.buttonNumber == 1 ? .right : event.buttonNumber == 2 ? .middle : .left
        }
    }

    /// Protocol sign convention is the browser one: positive dy scrolls content down.
    /// NSEvent already reports the user's natural-scrolling preference, so both axes flip.
    public static func scroll(from event: NSEvent) -> DataChannelMessage {
        let precise = event.hasPreciseScrollingDeltas
        let dx = precise ? -event.scrollingDeltaX : -event.deltaX
        let dy = precise ? -event.scrollingDeltaY : -event.deltaY
        var phase: ScrollPhase? = nil
        if event.momentumPhase.contains(.changed) || event.momentumPhase.contains(.began) { phase = .momentum }
        else if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.changed) { phase = .changed }
        else if event.phase.contains(.ended) || event.phase.contains(.cancelled) { phase = .ended }
        let clamp = { (v: CGFloat) -> Double in Double(min(max(v, -Limits.maxScrollDelta), Limits.maxScrollDelta)) }
        return .scroll(dx: clamp(dx), dy: clamp(dy), precise: precise, phase: phase)
    }
}
