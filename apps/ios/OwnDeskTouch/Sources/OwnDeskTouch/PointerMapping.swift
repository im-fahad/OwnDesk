import Foundation

/// Where a finger is, in the Mac's coordinates.
///
/// Two transforms sit between the two: the iPhone may be magnifying and shifting the picture, and
/// the picture is letterboxed inside its view. Getting either wrong puts the pointer somewhere the
/// finger is not, which is easy to mistake for a slow connection or a shaky hand, so the arithmetic
/// lives here on its own where it can be tested. It is the Android app's PointerMapping.kt, unchanged.
public enum PointerMapping {
    /// A view point to a fraction of the remote display, 0 to 1 on each axis. `view*` describe the
    /// video view before magnification; `scale` and `pan*` are the magnification applied about its
    /// centre.
    public static func normalized(
        x: Double, y: Double,
        viewLeft: Double, viewTop: Double, viewWidth: Double, viewHeight: Double,
        scale: Double, panX: Double, panY: Double,
        frameAspect: Double
    ) -> (x: Double, y: Double) {
        guard viewWidth > 0, viewHeight > 0, frameAspect > 0, scale > 0 else { return (0, 0) }

        let centreX = viewLeft + viewWidth / 2
        let centreY = viewTop + viewHeight / 2
        let localX = viewWidth / 2 + (x - centreX - panX) / scale
        let localY = viewHeight / 2 + (y - centreY - panY) / scale

        let content = contentSize(viewWidth: viewWidth, viewHeight: viewHeight, frameAspect: frameAspect)
        let left = (viewWidth - content.width) / 2
        let top = (viewHeight - content.height) / 2
        let nx = min(max((localX - left) / content.width, 0), 1)
        let ny = min(max((localY - top) / content.height, 0), 1)
        return (nx, ny)
    }

    /// How large the picture is inside its view once fitted, before any magnification.
    public static func contentSize(viewWidth: Double, viewHeight: Double, frameAspect: Double) -> (width: Double, height: Double) {
        guard viewWidth > 0, viewHeight > 0, frameAspect > 0 else { return (0, 0) }
        if viewWidth / viewHeight > frameAspect {
            return (viewHeight * frameAspect, viewHeight)
        }
        return (viewWidth, viewWidth / frameAspect)
    }

    /// The pan that keeps the point under the fingers still while the scale changes from `from` to
    /// `to`. Without it a pinch drifts, and the thing being zoomed towards slides off the screen.
    public static func panAfterZoom(focus: Double, centre: Double, pan: Double, from: Double, to: Double) -> Double {
        guard from > 0 else { return pan }
        let ratio = to / from
        return focus - centre - (focus - centre - pan) * ratio
    }

    /// Keeps a magnified picture covering its view, so no black edge appears while panning.
    public static func clampPan(_ pan: Double, viewSize: Double, scale: Double) -> Double {
        let limit = viewSize * (scale - 1) / 2
        guard limit > 0 else { return 0 }
        return min(max(pan, -limit), limit)
    }
}
