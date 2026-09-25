import OwnDeskTouch
import Testing

/// The arithmetic that decides where the Mac's pointer goes. The same cases as the Android app's
/// PointerMappingTest.kt.
@Suite struct PointerMappingTests {
    // A 1920x1080 desktop shown on a 3200x1440 view: the video is 2560 wide with black at the sides.
    let viewLeft = 320.0
    let viewTop = 0.0
    let viewWidth = 2560.0
    let viewHeight = 1440.0
    let aspect = 16.0 / 9.0

    func map(_ x: Double, _ y: Double, scale: Double = 1, panX: Double = 0, panY: Double = 0) -> (x: Double, y: Double) {
        PointerMapping.normalized(x: x, y: y, viewLeft: viewLeft, viewTop: viewTop, viewWidth: viewWidth, viewHeight: viewHeight,
                                  scale: scale, panX: panX, panY: panY, frameAspect: aspect)
    }

    @Test func theMiddleOfTheVideoIsTheMiddleOfTheScreen() {
        let p = map(viewLeft + viewWidth / 2, viewHeight / 2)
        #expect(abs(p.x - 0.5) < 0.001)
        #expect(abs(p.y - 0.5) < 0.001)
    }

    @Test func theEdgesOfTheVideoAreTheEdgesOfTheScreen() {
        #expect(abs(map(viewLeft, viewHeight / 2).x) < 0.001)
        #expect(abs(map(viewLeft + viewWidth, viewHeight / 2).x - 1) < 0.001)
        #expect(abs(map(viewLeft + viewWidth / 2, viewTop).y) < 0.001)
    }

    @Test func aTouchOnTheBlackBarsStaysInsideTheScreen() {
        let p = map(0, 720)
        #expect((0...1).contains(p.x), "x was \(p.x)")
        #expect((0...1).contains(p.y), "y was \(p.y)")
    }

    @Test func zoomingLeavesThePointUnderTheFingersWhereItWas() {
        let centreX = viewLeft + viewWidth / 2
        let centreY = viewTop + viewHeight / 2
        // Pinch around a point off to one side, the usual case: nobody zooms about the exact middle.
        let focusX = viewLeft + viewWidth * 0.7
        let focusY = viewHeight * 0.3

        var scale = 1.0, panX = 0.0, panY = 0.0
        let before = map(focusX, focusY)

        // Three pinch steps, as the recogniser would report them.
        for step in [1.3, 1.5, 1.2] {
            let previous = scale
            scale = min(scale * step, 4)
            panX = PointerMapping.panAfterZoom(focus: focusX, centre: centreX, pan: panX, from: previous, to: scale)
            panY = PointerMapping.panAfterZoom(focus: focusY, centre: centreY, pan: panY, from: previous, to: scale)
            panX = PointerMapping.clampPan(panX, viewSize: viewWidth, scale: scale)
            panY = PointerMapping.clampPan(panY, viewSize: viewHeight, scale: scale)
        }

        let after = map(focusX, focusY, scale: scale, panX: panX, panY: panY)
        #expect(scale > 2, "scale did not grow")
        #expect(abs(before.x - after.x) < 0.002, "x drifted")
        #expect(abs(before.y - after.y) < 0.002, "y drifted")
    }

    @Test func zoomedInATouchMapsIntoTheMagnifiedPartOfTheScreen() {
        // Magnified twice about the middle: the visible half is the middle half of the desktop.
        #expect(abs(map(viewLeft, viewHeight / 2, scale: 2).x - 0.25) < 0.002)
        #expect(abs(map(viewLeft + viewWidth, viewHeight / 2, scale: 2).x - 0.75) < 0.002)
    }

    @Test func panningCannotShowBlackBesideAMagnifiedPicture() {
        let limit = viewWidth * (2 - 1) / 2
        #expect(PointerMapping.clampPan(9999, viewSize: viewWidth, scale: 2) == limit)
        #expect(PointerMapping.clampPan(-9999, viewSize: viewWidth, scale: 2) == -limit)
        // Unmagnified there is nowhere to pan to.
        #expect(PointerMapping.clampPan(500, viewSize: viewWidth, scale: 1) == 0)
    }

    @Test func aTallerViewLetterboxesAtTheTopAndBottomInstead() {
        let p = PointerMapping.normalized(x: 540, y: 0, viewLeft: 0, viewTop: 0, viewWidth: 1080, viewHeight: 1920,
                                          scale: 1, panX: 0, panY: 0, frameAspect: aspect)
        // The frame occupies 1080x607 in the middle, so the very top of the view is above it.
        #expect(abs(p.y) < 0.001, "expected the top edge, got \(p.y)")
    }

    /// iPhone-specific: the video view fills the whole screen here, where Android sized it to the
    /// frame, so the picture's own size has to be worked out for trackpad speed.
    @Test func theFittedPictureKeepsTheFramesShape() {
        let wide = PointerMapping.contentSize(viewWidth: 852, viewHeight: 393, frameAspect: aspect)
        #expect(abs(wide.height - 393) < 0.001)
        #expect(abs(wide.width - 393 * aspect) < 0.001)
        let tall = PointerMapping.contentSize(viewWidth: 393, viewHeight: 852, frameAspect: aspect)
        #expect(abs(tall.width - 393) < 0.001)
        #expect(abs(tall.height - 393 / aspect) < 0.001)
    }
}
