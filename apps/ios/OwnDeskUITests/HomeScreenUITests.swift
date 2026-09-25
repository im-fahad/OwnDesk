import XCTest

/// The home screen and pairing sheet, with no Mac involved. Runs anywhere a simulator does.
final class HomeScreenUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAFreshInstallShowsItsFingerprintAndNoMacs() {
        let app = XCUIApplication()
        app.launchArguments = ["-OwnDeskReset", "YES"]
        app.launch()

        XCTAssertTrue(app.staticTexts["MACS YOU CAN CONTROL"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["None yet."].exists)
        let fingerprint = app.staticTexts["this-fingerprint"]
        XCTAssertTrue(fingerprint.exists)
        XCTAssertNotNil(fingerprint.label.range(of: #"^[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$"#, options: .regularExpression),
                        "not a fingerprint: \(fingerprint.label)")
    }

    func testTheFingerprintSurvivesARelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-OwnDeskReset", "YES"]
        app.launch()
        let first = app.staticTexts["this-fingerprint"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let before = first.label
        app.terminate()

        app.launchArguments = []
        app.launch()
        let again = app.staticTexts["this-fingerprint"]
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        XCTAssertEqual(again.label, before, "a new key on every launch would unpair every Mac")
    }

    func testPastingSomethingThatIsNotACodeSaysSo() {
        let app = XCUIApplication()
        app.launchArguments = ["-OwnDeskReset", "YES"]
        app.launch()

        app.buttons["pair-button"].tap()
        let field = app.textViews["code-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("hello")
        app.buttons["pair-confirm"].tap()

        // Answered in the sheet, which stays open for another try.
        XCTAssertTrue(app.staticTexts["pair-problem"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["code-field"].exists)
    }
}
