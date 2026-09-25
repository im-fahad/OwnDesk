import OwnDeskProtocol
import OwnDeskTouch
import Testing

/// The gesture contract, written down. The same cases as the Android app's GesturesTest.kt, so a
/// finger means the same thing on either phone.
@MainActor @Suite struct GesturesTests {
    final class Recorder: GestureOutput {
        var actions: [String] = []
        func moveTo(x: Double, y: Double) { actions.append("moveTo(\(Int(x)),\(Int(y)))") }
        func moveBy(dx: Double, dy: Double) { actions.append("moveBy(\(Int(dx)),\(Int(dy)))") }
        func click(_ button: MouseButton) { actions.append("click(\(button.rawValue))") }
        func buttonDown(_ button: MouseButton) { actions.append("down(\(button.rawValue))") }
        func buttonUp(_ button: MouseButton) { actions.append("up(\(button.rawValue))") }
        func scroll(dx: Double, dy: Double) { actions.append("scroll(\(Int(dx)),\(Int(dy)))") }
        func pan(dx: Double, dy: Double) { actions.append("pan(\(Int(dx)),\(Int(dy)))") }
        func holding(x: Double, y: Double, held: Bool) { actions.append("holding(\(held))") }
    }

    /// Timers that fire only when a test says so, so the tests do not wait for real time.
    final class FakeScheduler: GestureScheduler {
        private var next = 0
        private var pending: [(Int, () -> Void)] = []
        func after(_ delayMs: Int64, _ action: @escaping () -> Void) -> Int {
            next += 1
            pending.append((next, action))
            return next
        }
        func cancel(_ token: Int) { pending.removeAll { $0.0 == token } }
        func fireAll() {
            let due = pending
            pending.removeAll()
            due.forEach { $0.1() }
        }
    }

    let recorder = Recorder()
    let scheduler = FakeScheduler()
    let gestures: Gestures

    init() {
        gestures = Gestures(output: recorder, scheduler: scheduler)
    }

    var actions: [String] { recorder.actions }

    @Test func aTapIsALeftClickWhereTheFingerLanded() {
        gestures.down(x: 500, y: 400, time: 0)
        gestures.up(x: 500, y: 400, time: 100)
        #expect(actions == ["moveTo(500,400)", "click(left)"])
    }

    @Test func twoQuickTapsAreTwoClicksWhichTheMacReadsAsADoubleClick() {
        gestures.down(x: 500, y: 400, time: 0)
        gestures.up(x: 500, y: 400, time: 80)
        gestures.down(x: 502, y: 401, time: 200)
        gestures.up(x: 502, y: 401, time: 260)
        #expect(actions.filter { $0 == "click(left)" }.count == 2)
    }

    @Test func tappingTwiceAndHoldingStartsADragWhichIsHowTextIsSelected() {
        gestures.down(x: 500, y: 400, time: 0)
        gestures.up(x: 500, y: 400, time: 80)
        gestures.down(x: 500, y: 400, time: 200)
        scheduler.fireAll()                                              // held past the drag threshold
        gestures.move(count: 1, x: 700, y: 400, focusX: 700, focusY: 400) // dragged across
        gestures.up(x: 700, y: 400, time: 900)

        #expect(actions.contains("down(left)"), "no button was held: \(actions)")
        #expect(actions.contains("holding(true)"), "the hold was not shown")
        #expect(actions.contains("up(left)"), "the button was never released")
        #expect(actions.contains("moveTo(700,400)"), "the pointer did not follow the finger")
        #expect(actions.filter { $0 == "click(left)" }.count == 1, "the drag also clicked")
    }

    @Test func holdingOneFingerStillIsARightClick() {
        gestures.down(x: 500, y: 400, time: 0)
        scheduler.fireAll()
        gestures.up(x: 500, y: 400, time: 700)
        #expect(actions == ["moveTo(500,400)", "click(right)"])
    }

    @Test func tappingWithTwoFingersIsARightClick() {
        gestures.down(x: 500, y: 400, time: 0)
        gestures.pointerDown(count: 2, focusX: 520, focusY: 400, time: 20)
        gestures.up(x: 520, y: 400, time: 120)
        #expect(actions.contains("click(right)"), "expected a right click, got \(actions)")
        #expect(!actions.contains("click(left)"), "a left click slipped through")
    }

    @Test func tappingWithThreeFingersIsAMiddleClick() {
        gestures.down(x: 500, y: 400, time: 0)
        gestures.pointerDown(count: 2, focusX: 520, focusY: 400, time: 10)
        gestures.pointerDown(count: 3, focusX: 540, focusY: 400, time: 20)
        gestures.up(x: 540, y: 400, time: 120)
        #expect(actions.contains("click(middle)"), "expected a middle click, got \(actions)")
    }

    @Test func draggingTwoFingersScrollsAndIsNotAClick() {
        gestures.down(x: 500, y: 400, time: 0)
        gestures.pointerDown(count: 2, focusX: 520, focusY: 400, time: 20)
        gestures.move(count: 2, x: 520, y: 380, focusX: 520, focusY: 380)
        gestures.move(count: 2, x: 520, y: 340, focusX: 520, focusY: 340)
        gestures.up(x: 520, y: 340, time: 300)
        #expect(actions.contains { $0.hasPrefix("scroll(") }, "nothing scrolled: \(actions)")
        #expect(!actions.contains { $0.hasPrefix("click(") }, "a moved gesture also clicked")
    }

    @Test func twoFingersPanThePictureInsteadOfScrollingWhileItIsMagnified() {
        gestures.magnified = true
        gestures.down(x: 500, y: 400, time: 0)
        gestures.pointerDown(count: 2, focusX: 520, focusY: 400, time: 20)
        gestures.move(count: 2, x: 520, y: 360, focusX: 520, focusY: 360)
        gestures.up(x: 520, y: 360, time: 300)
        #expect(actions.contains { $0.hasPrefix("pan(") }, "nothing panned: \(actions)")
        #expect(!actions.contains { $0.hasPrefix("scroll(") }, "it scrolled the Mac as well")
    }

    @Test func aPinchNeitherScrollsNorClicks() {
        gestures.down(x: 500, y: 400, time: 0)
        gestures.pointerDown(count: 2, focusX: 520, focusY: 400, time: 20)
        gestures.pinching = true
        gestures.move(count: 2, x: 560, y: 400, focusX: 540, focusY: 400)
        gestures.up(x: 540, y: 400, time: 300)
        #expect(!actions.contains { $0.hasPrefix("scroll(") || $0.hasPrefix("click(") }, "a pinch produced \(actions)")
    }

    /// iPhone-specific: a quick pinch whose fingers move apart evenly leaves their midpoint still, so
    /// without the pinching flag surviving to the lift it would read as a two-finger tap.
    @Test func aQuickEvenPinchIsNotARightClick() {
        gestures.down(x: 500, y: 400, time: 0)
        gestures.pointerDown(count: 2, focusX: 520, focusY: 400, time: 20)
        gestures.pinching = true
        gestures.move(count: 2, x: 480, y: 400, focusX: 520, focusY: 400)
        gestures.up(x: 480, y: 400, time: 200)
        #expect(!actions.contains("click(right)"), "a pinch clicked: \(actions)")
    }

    @Test func inTrackpadModeTheFingerNudgesThePointerInsteadOfPlacingIt() {
        gestures.mode = .trackpad
        gestures.down(x: 500, y: 400, time: 0)
        gestures.move(count: 1, x: 540, y: 430, focusX: 540, focusY: 430)
        gestures.up(x: 540, y: 430, time: 200)
        #expect(!actions.contains { $0.hasPrefix("moveTo(") }, "the pointer was placed: \(actions)")
        #expect(actions.contains { $0.hasPrefix("moveBy(") }, "the pointer did not move: \(actions)")
    }

    @Test func movingAfterTouchingDownCancelsTheRightClick() {
        gestures.down(x: 500, y: 400, time: 0)
        gestures.move(count: 1, x: 600, y: 400, focusX: 600, focusY: 400)
        scheduler.fireAll()
        gestures.up(x: 600, y: 400, time: 800)
        #expect(!actions.contains("click(right)"), "holding still was assumed: \(actions)")
    }

    @Test func aCancelledGestureReleasesAHeldButton() {
        gestures.down(x: 500, y: 400, time: 0)
        gestures.up(x: 500, y: 400, time: 80)
        gestures.down(x: 500, y: 400, time: 200)
        scheduler.fireAll()
        gestures.cancel()
        #expect(actions.contains("up(left)"), "the button was left down")
        #expect(actions.contains("holding(false)"), "the hold mark was left showing")
    }

    @Test func theFirstTapEverIsNotTakenForTheSecondOfAPair() {
        // At time zero, at the origin, where an uninitialised "last tap" would sit.
        gestures.down(x: 0, y: 0, time: 0)
        scheduler.fireAll()
        gestures.up(x: 0, y: 0, time: 700)
        #expect(actions.contains("click(right)"), "a hold at the start began a drag: \(actions)")
        #expect(!actions.contains("down(left)"))
    }
}
