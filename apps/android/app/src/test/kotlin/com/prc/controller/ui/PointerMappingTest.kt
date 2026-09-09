package com.prc.controller.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * The arithmetic that decides where the Mac's pointer goes. It is worth testing on its own because
 * the symptom of getting it wrong is subtle: everything works, the pointer is simply in the wrong
 * place, and on a phone that is easy to mistake for a slow connection or a shaky hand.
 */
class PointerMappingTest {

    // A 1920x1080 desktop shown on a 3200x1440 phone: the video is 2560 wide with black at the sides.
    private val viewLeft = 320f
    private val viewTop = 0f
    private val viewWidth = 2560f
    private val viewHeight = 1440f
    private val aspect = 16f / 9f

    private fun map(x: Float, y: Float, scale: Float = 1f, panX: Float = 0f, panY: Float = 0f) =
        PointerMapping.normalized(x, y, viewLeft, viewTop, viewWidth, viewHeight, scale, panX, panY, aspect)

    @Test
    fun `the middle of the video is the middle of the screen`() {
        val (x, y) = map(viewLeft + viewWidth / 2f, viewHeight / 2f)
        assertEquals(0.5f, x, 0.001f)
        assertEquals(0.5f, y, 0.001f)
    }

    @Test
    fun `the edges of the video are the edges of the screen`() {
        val (leftX, _) = map(viewLeft, viewHeight / 2f)
        val (rightX, _) = map(viewLeft + viewWidth, viewHeight / 2f)
        val (_, topY) = map(viewLeft + viewWidth / 2f, viewTop)
        assertEquals(0f, leftX, 0.001f)
        assertEquals(1f, rightX, 0.001f)
        assertEquals(0f, topY, 0.001f)
    }

    @Test
    fun `a touch on the black bars stays inside the screen`() {
        val (x, y) = map(0f, 720f)
        assertTrue("x was $x", x in 0f..1f)
        assertTrue("y was $y", y in 0f..1f)
    }

    @Test
    fun `zooming leaves the point under the fingers where it was`() {
        val centreX = viewLeft + viewWidth / 2f
        val centreY = viewTop + viewHeight / 2f
        // Pinch around a point off to one side, the usual case: nobody zooms about the exact middle.
        val focusX = viewLeft + viewWidth * 0.7f
        val focusY = viewHeight * 0.3f

        var scale = 1f
        var panX = 0f
        var panY = 0f
        val before = map(focusX, focusY, scale, panX, panY)

        // Three pinch steps, as the detector would report them.
        for (step in listOf(1.3f, 1.5f, 1.2f)) {
            val previous = scale
            scale = (scale * step).coerceAtMost(4f)
            panX = PointerMapping.panAfterZoom(focusX, centreX, panX, previous, scale)
            panY = PointerMapping.panAfterZoom(focusY, centreY, panY, previous, scale)
            panX = PointerMapping.clampPan(panX, viewWidth, scale)
            panY = PointerMapping.clampPan(panY, viewHeight, scale)
        }

        val after = map(focusX, focusY, scale, panX, panY)
        assertTrue("scale did not grow", scale > 2f)
        assertEquals("x drifted", before.first, after.first, 0.002f)
        assertEquals("y drifted", before.second, after.second, 0.002f)
    }

    @Test
    fun `zoomed in, a touch maps into the magnified part of the screen`() {
        // Magnified twice about the middle: the visible half is the middle half of the desktop.
        val (leftX, _) = map(viewLeft, viewHeight / 2f, scale = 2f)
        val (rightX, _) = map(viewLeft + viewWidth, viewHeight / 2f, scale = 2f)
        assertEquals(0.25f, leftX, 0.002f)
        assertEquals(0.75f, rightX, 0.002f)
    }

    @Test
    fun `panning cannot show black beside a magnified picture`() {
        val limit = viewWidth * (2f - 1f) / 2f
        assertEquals(limit, PointerMapping.clampPan(9999f, viewWidth, 2f), 0.001f)
        assertEquals(-limit, PointerMapping.clampPan(-9999f, viewWidth, 2f), 0.001f)
        // Unmagnified there is nowhere to pan to.
        assertEquals(0f, PointerMapping.clampPan(500f, viewWidth, 1f), 0.001f)
    }

    @Test
    fun `a taller phone letterboxes at the top and bottom instead`() {
        val (_, y) = PointerMapping.normalized(
            x = 540f, y = 0f, viewLeft = 0f, viewTop = 0f, viewWidth = 1080f, viewHeight = 1920f,
            scale = 1f, panX = 0f, panY = 0f, frameAspect = aspect,
        )
        // The frame occupies 1080x607 in the middle, so the very top of the view is above it.
        assertTrue("expected the top edge, got $y", abs(y) < 0.001f)
    }
}
