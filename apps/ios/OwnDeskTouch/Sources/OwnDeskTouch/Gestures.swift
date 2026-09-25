import Foundation
import OwnDeskProtocol

/// Where a gesture's effects go: the Mac's pointer and buttons, or the picture of the Mac.
@MainActor
public protocol GestureOutput: AnyObject {
    func moveTo(x: Double, y: Double)
    func moveBy(dx: Double, dy: Double)
    func click(_ button: MouseButton)
    func buttonDown(_ button: MouseButton)
    func buttonUp(_ button: MouseButton)
    func scroll(dx: Double, dy: Double)
    func pan(dx: Double, dy: Double)
    /// Shows or hides the mark that says the button is being held.
    func holding(x: Double, y: Double, held: Bool)
}

/// Delayed actions, behind a protocol so tests decide when time passes.
@MainActor
public protocol GestureScheduler: AnyObject {
    func after(_ delayMs: Int64, _ action: @escaping () -> Void) -> Int
    func cancel(_ token: Int)
}

/// What a finger means.
///
/// The same contract as the Android app's Gestures.kt, which follows what the established remote
/// desktop apps settled on, because those gestures are already in people's hands: a tap clicks, two
/// fingers scroll, pinch magnifies, and a drag with the button held has to be entered deliberately by
/// tapping twice and holding. No app treats a plain finger drag as a drag, because then nothing could
/// be pointed at without dragging it, and without it there is no way to select text or move a window.
///
/// Coordinates are in the view's own units, points on an iPhone, and times in milliseconds. Touches
/// arrive on the main thread, so that is where this lives.
@MainActor
public final class Gestures {
    /// Where the pointer goes when a finger moves.
    public enum Mode: String, Sendable, CaseIterable {
        /// The pointer follows the finger to where it touched. Quick, hard to be precise.
        case touch
        /// The finger nudges the pointer from where it was, like a laptop trackpad. Precise.
        case trackpad
    }

    public struct Timing: Sendable {
        public var longPressMs: Int64 = 550
        public var doubleTapMs: Int64 = 320
        public var dragHoldMs: Int64 = 220
        public var tapMs: Int64 = 450
        /// How far a finger may wander and still be holding still. Android's value was twelve
        /// pixels; this is the same distance in points on a three-times screen, plus the extra an
        /// iPhone's larger touch area reports while a finger rests.
        public var touchSlop: Double = 8
        public var doubleTapSlop: Double = 30
        public var moveSlop: Double = 0.5

        public init() {}
    }

    public var mode: Mode = .touch
    /// While the picture is magnified, two fingers move the picture instead of scrolling the Mac.
    public var magnified = false
    /// Set while a pinch is being recognised, so the same fingers do not also scroll or click.
    public var pinching = false

    private weak var output: GestureOutput?
    private let scheduler: GestureScheduler
    private let timing: Timing

    private var maxPointers = 0
    private var downTime: Int64 = 0
    private var downX = 0.0, downY = 0.0
    private var lastX = 0.0, lastY = 0.0
    private var lastFocusX = 0.0, lastFocusY = 0.0
    private var moved = false
    private var multiMoved = false
    private var dragging = false
    private var rightFired = false
    // Far enough in the past that the first tap can never count as the second of a pair.
    private var lastTapUp: Int64 = .min / 2
    private var lastTapX = 0.0, lastTapY = 0.0
    private var pending: Int?

    public init(output: GestureOutput, scheduler: GestureScheduler, timing: Timing = Timing()) {
        self.output = output
        self.scheduler = scheduler
        self.timing = timing
    }

    public func down(x: Double, y: Double, time: Int64) {
        cancelPending()
        maxPointers = 1
        downTime = time
        downX = x; downY = y
        lastX = x; lastY = y
        moved = false
        multiMoved = false
        rightFired = false
        dragging = false

        if mode == .touch { output?.moveTo(x: x, y: y) }

        let secondTap = time - lastTapUp <= timing.doubleTapMs
            && hypot(x - lastTapX, y - lastTapY) <= timing.doubleTapSlop
        if secondTap {
            // Tapped twice and still down: held a moment longer this becomes a drag, which is how
            // text gets selected. Lifted sooner it is simply a double click.
            pending = scheduler.after(timing.dragHoldMs) { [weak self] in self?.startDrag(x: x, y: y) }
        } else {
            pending = scheduler.after(timing.longPressMs) { [weak self] in self?.rightClick() }
        }
    }

    public func pointerDown(count: Int, focusX: Double, focusY: Double, time: Int64) {
        maxPointers = max(maxPointers, count)
        cancelPending()
        lastFocusX = focusX
        lastFocusY = focusY
        multiMoved = false
    }

    public func move(count: Int, x: Double, y: Double, focusX: Double, focusY: Double) {
        if count >= 2 {
            let dx = focusX - lastFocusX
            let dy = focusY - lastFocusY
            lastFocusX = focusX
            lastFocusY = focusY
            if abs(dx) > timing.moveSlop || abs(dy) > timing.moveSlop { multiMoved = true }
            if pinching { return }
            if magnified { output?.pan(dx: dx, dy: dy) } else if multiMoved { output?.scroll(dx: dx, dy: dy) }
            return
        }

        let dx = x - lastX
        let dy = y - lastY
        lastX = x; lastY = y
        if !moved, hypot(x - downX, y - downY) > timing.touchSlop {
            moved = true
            if !dragging { cancelPending() }
        }
        guard moved || dragging else { return }
        switch mode {
        case .touch: output?.moveTo(x: x, y: y)
        case .trackpad: output?.moveBy(dx: dx, dy: dy)
        }
    }

    public func up(x: Double, y: Double, time: Int64) {
        cancelPending()
        let heldFor = time - downTime
        if dragging {
            output?.buttonUp(.left)
            output?.holding(x: x, y: y, held: false)
        } else if maxPointers >= 3, !multiMoved, heldFor < timing.tapMs {
            // A tap with two or three fingers is a right or middle click, as long as those fingers
            // did not move: moving them was a scroll or a pinch.
            output?.click(.middle)
        } else if maxPointers == 2, !multiMoved, !pinching, heldFor < timing.tapMs {
            output?.click(.right)
        } else if maxPointers == 1, !moved, !rightFired, heldFor < timing.longPressMs {
            output?.click(.left)
            lastTapUp = time
            lastTapX = x
            lastTapY = y
        }
        dragging = false
        maxPointers = 0
    }

    public func cancel() {
        cancelPending()
        if dragging {
            output?.buttonUp(.left)
            output?.holding(x: lastX, y: lastY, held: false)
        }
        dragging = false
        maxPointers = 0
    }

    private func startDrag(x: Double, y: Double) {
        pending = nil
        dragging = true
        output?.buttonDown(.left)
        output?.holding(x: x, y: y, held: true)
    }

    private func rightClick() {
        pending = nil
        rightFired = true
        output?.click(.right)
    }

    private func cancelPending() {
        if let pending { scheduler.cancel(pending) }
        pending = nil
    }
}
