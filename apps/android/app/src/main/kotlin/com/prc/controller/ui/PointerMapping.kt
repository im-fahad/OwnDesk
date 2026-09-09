package com.prc.controller.ui

/**
 * Where a finger is, in the Mac's coordinates.
 *
 * Two transforms sit between the two: the phone may be magnifying and shifting the picture, and the
 * picture may be letterboxed inside its view. Getting either wrong puts the pointer somewhere the
 * finger is not, which is the difference between a usable remote and a frustrating one, so the
 * arithmetic lives here on its own where it can be tested without a phone.
 */
object PointerMapping {

    /** A screen point to a fraction of the remote display, 0 to 1 on each axis. */
    fun normalized(
        x: Float,
        y: Float,
        viewLeft: Float,
        viewTop: Float,
        viewWidth: Float,
        viewHeight: Float,
        scale: Float,
        panX: Float,
        panY: Float,
        frameAspect: Float,
    ): Pair<Float, Float> {
        if (viewWidth <= 0f || viewHeight <= 0f || frameAspect <= 0f) return 0f to 0f

        val centreX = viewLeft + viewWidth / 2f
        val centreY = viewTop + viewHeight / 2f
        val localX = viewWidth / 2f + (x - centreX - panX) / scale
        val localY = viewHeight / 2f + (y - centreY - panY) / scale

        val viewAspect = viewWidth / viewHeight
        val contentWidth: Float
        val contentHeight: Float
        if (viewAspect > frameAspect) {
            contentHeight = viewHeight
            contentWidth = viewHeight * frameAspect
        } else {
            contentWidth = viewWidth
            contentHeight = viewWidth / frameAspect
        }
        val left = (viewWidth - contentWidth) / 2f
        val top = (viewHeight - contentHeight) / 2f
        val nx = ((localX - left) / contentWidth).coerceIn(0f, 1f)
        val ny = ((localY - top) / contentHeight).coerceIn(0f, 1f)
        return nx to ny
    }

    /**
     * The pan that keeps the point under the fingers still while the scale changes from `from` to
     * `to`. Without it a pinch drifts, and the thing being zoomed towards slides off the screen.
     */
    fun panAfterZoom(focus: Float, centre: Float, pan: Float, from: Float, to: Float): Float {
        if (from <= 0f) return pan
        val ratio = to / from
        return focus - centre - (focus - centre - pan) * ratio
    }

    /** Keeps a magnified picture covering its view, so no black edge appears while panning. */
    fun clampPan(pan: Float, viewSize: Float, scale: Float): Float {
        val limit = viewSize * (scale - 1f) / 2f
        if (limit <= 0f) return 0f
        return pan.coerceIn(-limit, limit)
    }
}
