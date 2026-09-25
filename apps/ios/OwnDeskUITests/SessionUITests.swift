import XCTest

/// Pairs with a real Mac host and drives a session: taps, holds, two-finger taps, a pinch, trackpad
/// mode, the keyboard and the key bar. It needs a host, so it skips unless one is named:
/// scripts/test-ios-simulator.sh starts a headless one that prints every input it receives, runs
/// this, and then checks the host saw each gesture as the right mouse or key event.
final class SessionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testPairConnectAndDrive() throws {
        let env = ProcessInfo.processInfo.environment
        guard let code = env["OWNDESK_PAIR_CODE"], !code.isEmpty else {
            throw XCTSkip("no host to pair with; run scripts/test-ios-simulator.sh")
        }

        let app = XCUIApplication()
        app.launchArguments = ["-OwnDeskReset", "YES", "-OwnDeskPairCode", code]
        app.launch()

        // The host approves by itself in the test; the Mac then appears in the list.
        let mac = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'mac-'")).firstMatch
        XCTAssertTrue(mac.waitForExistence(timeout: 60), "the Mac never appeared: pairing did not finish")
        snap("home")
        mac.tap()

        let surface = app.descendants(matching: .any)["session-surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 15))

        // Connected and streaming H.264, read from the peer connection by the info panel.
        app.buttons["session-info"].tap()
        let codec = app.staticTexts["info-codec"]
        XCTAssertTrue(codec.waitForExistence(timeout: 30), "no video arrived")
        XCTAssertEqual(codec.label, "H264")
        snap("session-info")
        app.buttons["session-info"].tap()
        snap("session-portrait")

        // Each gesture is followed by a pause, so the host's log shows them apart.
        let centre = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        centre.tap()                                   // left click at the centre
        pause()
        surface.twoFingerTap()                         // right click
        pause()
        centre.press(forDuration: 1.0)                 // held still: right click
        pause()
        surface.pinch(withScale: 2.5, velocity: 2)     // magnify here, nothing sent
        pause()
        surface.pinch(withScale: 0.2, velocity: -2)    // and back
        pause()

        app.buttons["session-mode"].tap()              // trackpad
        XCTAssertEqual(app.buttons["session-mode"].value as? String, "trackpad")
        let from = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        let to = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: to)   // relative moves to the right
        pause()
        app.buttons["session-mode"].tap()              // back to touch
        XCTAssertEqual(app.buttons["session-mode"].value as? String, "touch")

        app.buttons["session-keyboard"].tap()
        XCTAssertTrue(app.buttons["key-Escape"].waitForExistence(timeout: 5), "the key bar did not appear")
        app.typeText("hi")                             // text, never logged, only counted
        pause()
        snap("keyboard")
        app.buttons["key-Escape"].tap()                // Escape
        pause()
        app.buttons["key-meta"].tap()                  // ⌘ then c: Command-C
        app.typeText("c")
        pause()
        // The sidebar stays above the keyboard, so its own icon closes it.
        app.buttons["session-keyboard"].tap()
        XCTAssertTrue(app.buttons["key-Escape"].waitForNonExistence(timeout: 5), "the keyboard did not close")

        // Landscape: the sidebar moves to the bar beside the picture, and a tap still lands where
        // the finger is.
        XCUIDevice.shared.orientation = .landscapeLeft
        pause()
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        pause()
        snap("session-landscape")
        app.buttons["session-keyboard"].tap()
        XCTAssertTrue(app.buttons["key-hide"].waitForExistence(timeout: 5))
        pause()
        snap("keyboard-landscape")
        app.buttons["key-hide"].tap()                  // pinned at the end of the bar
        XCTAssertTrue(app.buttons["key-Escape"].waitForNonExistence(timeout: 5), "the keyboard did not close")
        XCUIDevice.shared.orientation = .portrait
        pause()

        app.buttons["session-end"].tap()
        app.alerts.buttons["End"].tap()
        XCTAssertTrue(app.staticTexts["MACS YOU CAN CONTROL"].waitForExistence(timeout: 10), "the session did not close")
    }

    private func pause() {
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// Saves a screenshot when a folder is named, so the screens can be looked at after a run:
    /// SCREENSHOTS=<folder> scripts/test-ios-simulator.sh
    private func snap(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["OWNDESK_SCREENSHOTS"], !folder.isEmpty else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
