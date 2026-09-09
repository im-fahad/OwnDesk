import CoreGraphics
import Foundation
import Testing
@testable import PRCAgentCore
@Suite("Relative pointer moves")
struct RelativeCursorTests {
    /// The bug this exists to prevent: asking the system where the cursor is after every event
    /// loses most of a fast drag, because it has not moved there yet.
    @Test func accumulatesInsteadOfReadingTheCursorEachTime() {
        var cursor = RelativeCursor()
        let stale = { CGPoint(x: 100, y: 100) }   // a system that never catches up
        var last = CGPoint.zero
        for step in 0..<10 {
            last = cursor.next(dx: 10, dy: 5, now: Int64(step * 10), live: stale)
        }
        #expect(last.x == 200)
        #expect(last.y == 150)
    }

    @Test func resynchronisesAfterAPause() {
        var cursor = RelativeCursor()
        let live = { CGPoint(x: 500, y: 400) }
        _ = cursor.next(dx: 10, dy: 0, now: 0, live: live)
        // Long enough to mean the user let go and may have moved the mouse themselves.
        let after = cursor.next(dx: 10, dy: 0, now: RelativeCursor.resyncAfterMs + 1, live: live)
        #expect(after.x == 510)
    }

    @Test func anAbsoluteMoveBecomesTheNewStartingPoint() {
        var cursor = RelativeCursor()
        cursor.placed(at: CGPoint(x: 900, y: 300), now: 0)
        let next = cursor.next(dx: -50, dy: 20, now: 10, live: { CGPoint(x: 0, y: 0) })
        #expect(next.x == 850)
        #expect(next.y == 320)
    }
}
