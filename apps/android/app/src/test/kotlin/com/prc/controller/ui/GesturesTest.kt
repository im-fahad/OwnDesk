package com.prc.controller.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The gesture contract, written down. Multi-touch cannot be synthesised over the debugging bridge,
 * so this is the only place these gestures can be checked at all, and it is where they are kept
 * honest against what the established remote desktop apps do.
 */
class GesturesTest {

    private val actions = mutableListOf<String>()

    private val output = object : Gestures.Output {
        override fun moveTo(x: Float, y: Float) { actions += "moveTo(${x.toInt()},${y.toInt()})" }
        override fun moveBy(dx: Float, dy: Float) { actions += "moveBy(${dx.toInt()},${dy.toInt()})" }
        override fun click(button: String) { actions += "click($button)" }
        override fun buttonDown(button: String) { actions += "down($button)" }
        override fun buttonUp(button: String) { actions += "up($button)" }
        override fun scroll(dx: Float, dy: Float) { actions += "scroll(${dx.toInt()},${dy.toInt()})" }
        override fun pan(dx: Float, dy: Float) { actions += "pan(${dx.toInt()},${dy.toInt()})" }
        override fun holding(x: Float, y: Float, held: Boolean) { actions += "holding($held)" }
    }

    /** Timers that fire only when a test says so, so the tests do not wait for real time. */
    private class FakeScheduler : Gestures.Scheduler {
        private var next = 0
        val pending = LinkedHashMap<Any, () -> Unit>()
        override fun after(delayMs: Long, action: () -> Unit): Any {
            val token = next++
            pending[token] = action
            return token
        }
        override fun cancel(token: Any) { pending.remove(token) }
        fun fireAll() {
            val actions = pending.values.toList()
            pending.clear()
            actions.forEach { it() }
        }
    }

    private val scheduler = FakeScheduler()
    private val gestures = Gestures(output, scheduler)

    @Test
    fun `a tap is a left click where the finger landed`() {
        gestures.down(500f, 400f, 0)
        gestures.up(500f, 400f, 100)
        assertEquals(listOf("moveTo(500,400)", "click(left)"), actions)
    }

    @Test
    fun `two quick taps are two clicks, which the Mac reads as a double click`() {
        gestures.down(500f, 400f, 0)
        gestures.up(500f, 400f, 80)
        gestures.down(502f, 401f, 200)
        gestures.up(502f, 401f, 260)
        assertEquals(2, actions.count { it == "click(left)" })
    }

    @Test
    fun `tapping twice and holding starts a drag, which is how text is selected`() {
        gestures.down(500f, 400f, 0)
        gestures.up(500f, 400f, 80)
        gestures.down(500f, 400f, 200)
        scheduler.fireAll()                      // held past the drag threshold
        gestures.move(1, 700f, 400f, 700f, 400f) // dragged across
        gestures.up(700f, 400f, 900)

        assertTrue("no button was held: $actions", actions.contains("down(left)"))
        assertTrue("the hold was not shown", actions.contains("holding(true)"))
        assertTrue("the button was never released", actions.contains("up(left)"))
        assertTrue("the pointer did not follow the finger", actions.contains("moveTo(700,400)"))
        assertEquals("the drag also clicked", 1, actions.count { it == "click(left)" })
    }

    @Test
    fun `holding one finger still is a right click`() {
        gestures.down(500f, 400f, 0)
        scheduler.fireAll()
        gestures.up(500f, 400f, 700)
        assertEquals(listOf("moveTo(500,400)", "click(right)"), actions)
    }

    @Test
    fun `tapping with two fingers is a right click`() {
        gestures.down(500f, 400f, 0)
        gestures.pointerDown(2, 520f, 400f, 20)
        gestures.up(520f, 400f, 120)
        assertTrue("expected a right click, got $actions", actions.contains("click(right)"))
        assertTrue("a left click slipped through", actions.none { it == "click(left)" })
    }

    @Test
    fun `tapping with three fingers is a middle click`() {
        gestures.down(500f, 400f, 0)
        gestures.pointerDown(2, 520f, 400f, 10)
        gestures.pointerDown(3, 540f, 400f, 20)
        gestures.up(540f, 400f, 120)
        assertTrue("expected a middle click, got $actions", actions.contains("click(middle)"))
    }

    @Test
    fun `dragging two fingers scrolls, and is not a click`() {
        gestures.down(500f, 400f, 0)
        gestures.pointerDown(2, 520f, 400f, 20)
        gestures.move(2, 520f, 380f, 520f, 380f)
        gestures.move(2, 520f, 340f, 520f, 340f)
        gestures.up(520f, 340f, 300)
        assertTrue("nothing scrolled: $actions", actions.any { it.startsWith("scroll(") })
        assertTrue("a moved gesture also clicked", actions.none { it.startsWith("click(") })
    }

    @Test
    fun `two fingers pan the picture instead of scrolling while it is magnified`() {
        gestures.magnified = true
        gestures.down(500f, 400f, 0)
        gestures.pointerDown(2, 520f, 400f, 20)
        gestures.move(2, 520f, 360f, 520f, 360f)
        gestures.up(520f, 360f, 300)
        assertTrue("nothing panned: $actions", actions.any { it.startsWith("pan(") })
        assertTrue("it scrolled the Mac as well", actions.none { it.startsWith("scroll(") })
    }

    @Test
    fun `a pinch neither scrolls nor clicks`() {
        gestures.down(500f, 400f, 0)
        gestures.pointerDown(2, 520f, 400f, 20)
        gestures.pinching = true
        gestures.move(2, 560f, 400f, 540f, 400f)
        gestures.up(540f, 400f, 300)
        assertTrue("a pinch produced $actions", actions.none { it.startsWith("scroll(") || it.startsWith("click(") })
    }

    @Test
    fun `in trackpad mode the finger nudges the pointer instead of placing it`() {
        gestures.mode = Gestures.Mode.TRACKPAD
        gestures.down(500f, 400f, 0)
        gestures.move(1, 540f, 430f, 540f, 430f)
        gestures.up(540f, 430f, 200)
        assertTrue("the pointer was placed: $actions", actions.none { it.startsWith("moveTo(") })
        assertTrue("the pointer did not move: $actions", actions.any { it.startsWith("moveBy(") })
    }

    @Test
    fun `moving after touching down cancels the right click`() {
        gestures.down(500f, 400f, 0)
        gestures.move(1, 600f, 400f, 600f, 400f)
        scheduler.fireAll()
        gestures.up(600f, 400f, 800)
        assertTrue("holding still was assumed: $actions", actions.none { it == "click(right)" })
    }

    @Test
    fun `a cancelled gesture releases a held button`() {
        gestures.down(500f, 400f, 0)
        gestures.up(500f, 400f, 80)
        gestures.down(500f, 400f, 200)
        scheduler.fireAll()
        gestures.cancel()
        assertTrue("the button was left down", actions.contains("up(left)"))
        assertTrue("the hold mark was left showing", actions.contains("holding(false)"))
    }
}
