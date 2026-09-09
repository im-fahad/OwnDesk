package com.prc.controller.ui

import kotlin.math.abs
import kotlin.math.hypot

/**
 * What a finger means.
 *
 * The mapping follows what the established remote desktop apps settled on, because those gestures
 * are already in people's hands: a tap clicks, two fingers scroll, pinch magnifies, and a drag with
 * the button held has to be entered deliberately by tapping twice and holding. That last one is the
 * important one. No app treats a plain finger drag as a drag, because then nothing could be pointed
 * at without dragging it, and without it there is no way to select text or move a window.
 *
 * The logic is kept away from Android's event classes so it can be tested without a phone, which
 * matters here: multi-touch cannot be synthesised over the debugging bridge.
 */
class Gestures(
    private val out: Output,
    private val scheduler: Scheduler,
) {
    /** Where the pointer goes when a finger moves. */
    enum class Mode {
        /** The pointer follows the finger to where it touched. Quick, hard to be precise. */
        TOUCH,

        /** The finger nudges the pointer from where it was, like a laptop trackpad. Precise. */
        TRACKPAD,
    }

    interface Output {
        fun moveTo(x: Float, y: Float)
        fun moveBy(dx: Float, dy: Float)
        fun click(button: String)
        fun buttonDown(button: String)
        fun buttonUp(button: String)
        fun scroll(dx: Float, dy: Float)
        fun pan(dx: Float, dy: Float)
        /** Shows or hides the mark that says the button is being held. */
        fun holding(x: Float, y: Float, held: Boolean)
    }

    interface Scheduler {
        fun after(delayMs: Long, action: () -> Unit): Any
        fun cancel(token: Any)
    }

    var mode: Mode = Mode.TOUCH
    /** While the picture is magnified, two fingers move the picture instead of scrolling the Mac. */
    var magnified: Boolean = false
    /** Set while a pinch is being recognised, so the same fingers do not also scroll. */
    var pinching: Boolean = false

    private var maxPointers = 0
    private var downTime = 0L
    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var lastFocusX = 0f
    private var lastFocusY = 0f
    private var moved = false
    private var multiMoved = false
    private var dragging = false
    private var rightFired = false
    private var lastTapUp = 0L
    private var lastTapX = 0f
    private var lastTapY = 0f
    private var pending: Any? = null

    fun down(x: Float, y: Float, time: Long) {
        cancelPending()
        maxPointers = 1
        downTime = time
        downX = x; downY = y
        lastX = x; lastY = y
        moved = false
        multiMoved = false
        rightFired = false
        dragging = false

        if (mode == Mode.TOUCH) out.moveTo(x, y)

        val secondTap = time - lastTapUp <= DOUBLE_TAP_MS &&
            hypot(x - lastTapX, y - lastTapY) <= DOUBLE_TAP_SLOP
        pending = if (secondTap) {
            // Tapped twice and still down: held a moment longer this becomes a drag, which is how
            // text gets selected. Lifted sooner it is simply a double click.
            scheduler.after(DRAG_HOLD_MS) { startDrag(x, y) }
        } else {
            scheduler.after(LONG_PRESS_MS) { rightClick() }
        }
    }

    fun pointerDown(pointerCount: Int, focusX: Float, focusY: Float, time: Long) {
        maxPointers = maxOf(maxPointers, pointerCount)
        cancelPending()
        lastFocusX = focusX
        lastFocusY = focusY
        multiMoved = false
    }

    fun move(pointerCount: Int, x: Float, y: Float, focusX: Float, focusY: Float) {
        if (pointerCount >= 2) {
            val dx = focusX - lastFocusX
            val dy = focusY - lastFocusY
            lastFocusX = focusX
            lastFocusY = focusY
            if (abs(dx) > MOVE_SLOP || abs(dy) > MOVE_SLOP) multiMoved = true
            if (pinching) return
            if (magnified) out.pan(dx, dy) else if (multiMoved) out.scroll(dx, dy)
            return
        }

        val dx = x - lastX
        val dy = y - lastY
        lastX = x; lastY = y
        if (!moved && hypot(x - downX, y - downY) > TOUCH_SLOP) {
            moved = true
            if (!dragging) cancelPending()
        }
        if (!moved && !dragging) return
        when (mode) {
            Mode.TOUCH -> out.moveTo(x, y)
            Mode.TRACKPAD -> out.moveBy(dx, dy)
        }
    }

    fun up(x: Float, y: Float, time: Long) {
        cancelPending()
        val heldFor = time - downTime
        when {
            dragging -> {
                out.buttonUp("left")
                out.holding(x, y, false)
            }
            // A tap with two or three fingers is a right or middle click, as long as those fingers
            // did not move: moving them was a scroll or a pinch.
            maxPointers >= 3 && !multiMoved && heldFor < TAP_MS -> out.click("middle")
            maxPointers == 2 && !multiMoved && !pinching && heldFor < TAP_MS -> out.click("right")
            maxPointers == 1 && !moved && !rightFired && heldFor < LONG_PRESS_MS -> {
                out.click("left")
                lastTapUp = time
                lastTapX = x
                lastTapY = y
            }
        }
        dragging = false
        maxPointers = 0
    }

    fun cancel() {
        cancelPending()
        if (dragging) {
            out.buttonUp("left")
            out.holding(lastX, lastY, false)
        }
        dragging = false
        maxPointers = 0
    }

    private fun startDrag(x: Float, y: Float) {
        pending = null
        dragging = true
        out.buttonDown("left")
        out.holding(x, y, true)
    }

    private fun rightClick() {
        pending = null
        rightFired = true
        out.click("right")
    }

    private fun cancelPending() {
        pending?.let(scheduler::cancel)
        pending = null
    }

    companion object {
        const val LONG_PRESS_MS = 550L
        const val DOUBLE_TAP_MS = 320L
        const val DRAG_HOLD_MS = 220L
        const val TAP_MS = 450L
        const val TOUCH_SLOP = 12f
        const val DOUBLE_TAP_SLOP = 60f
        const val MOVE_SLOP = 0.5f
    }
}
