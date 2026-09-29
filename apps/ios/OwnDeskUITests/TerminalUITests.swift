import XCTest

/// Asks a Mac to allow this iPhone's terminal key, then opens a terminal on a real SSH server and
/// runs a command in it. Needs a host and an SSH server, so it skips unless they are named:
/// scripts/test-ios-simulator.sh starts the headless agent and a private sshd on this Mac, hands this
/// test the pairing code, and answers the host's key question with yes.
final class TerminalUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAskTheMacForAccessThenRunACommand() throws {
        let env = ProcessInfo.processInfo.environment
        guard let code = env["OWNDESK_PAIR_CODE"], !code.isEmpty,
              let port = env["OWNDESK_SSH_PORT"], let user = env["OWNDESK_SSH_USER"], let marker = env["OWNDESK_MARKER"]
        else { throw XCTSkip("no host or SSH server; run scripts/test-ios-simulator.sh") }

        // Pair, then ask the Mac from the terminal sheet, with the private server's port filled in.
        let app = XCUIApplication()
        app.launchArguments = ["-OwnDeskReset", "YES", "-OwnDeskPairCode", code]
        app.launch()
        let screenButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mac-'")).firstMatch
        XCTAssertTrue(screenButton.waitForExistence(timeout: 60), "pairing did not finish")
        let fingerprint = String(screenButton.identifier.dropFirst("mac-".count))
        let terminalButton = app.buttons["terminal-\(fingerprint)"]
        XCTAssertTrue(terminalButton.exists, "no terminal button beside the Mac")
        terminalButton.tap()

        let portField = app.textFields["ssh-port"]
        XCTAssertTrue(portField.waitForExistence(timeout: 10), "the terminal sheet did not open")
        portField.tap()
        portField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + port)

        app.buttons["terminal-ask"].tap()
        let result = app.staticTexts["terminal-ask-result"]
        let added = NSPredicate(format: "label CONTAINS 'added this iPhone' OR label CONTAINS 'already had'")
        expectation(for: added, evaluatedWith: result)
        waitForExpectations(timeout: 60)
        snap("terminal-asked")
        // The Mac's answer named the account, and the sheet filled it in.
        XCTAssertEqual(app.textFields["ssh-user"].value as? String, user)
        app.buttons["Cancel"].tap()
        app.terminate()

        // Straight into the terminal, at the address the private server listens on. No user name is
        // passed: the one the Mac sent is used. And no host key question: the Mac vouched for it.
        let local = "127.0.0.1:\(env["OWNDESK_AGENT_PORT"] ?? "47610")"
        app.launchArguments = ["-OwnDeskAddress", local, "-OwnDeskTerminal", fingerprint]
        app.launch()

        let terminal = app.descendants(matching: .any)["terminal-view"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 20))
        let message = app.staticTexts["terminal-message"]
        let connected = NSPredicate(format: "exists == false OR isHittable == false")
        expectation(for: connected, evaluatedWith: message)
        waitForExpectations(timeout: 20)
        XCTAssertFalse(app.alerts.buttons["Trust"].exists, "asked about a host key the Mac had vouched for")

        terminal.tap()
        app.typeText("echo owndesk-terminal-$((40+2)) > \(marker)\n")
        let deadline = Date().addingTimeInterval(15)
        var written = ""
        while Date() < deadline {
            written = (try? String(contentsOfFile: marker, encoding: .utf8)) ?? ""
            if written.contains("owndesk-terminal-42") { break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertEqual(written.trimmingCharacters(in: .whitespacesAndNewlines), "owndesk-terminal-42",
                       "the command never ran on the Mac")
        snap("terminal-shell")

        // Ending the shell ends the terminal, and says so.
        app.typeText("exit\n")
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.contains("ended"), "unexpected end: \(message.label)")
        snap("terminal-ended")
        app.buttons["terminal-close"].tap()
        XCTAssertTrue(app.staticTexts["MACS YOU CAN CONTROL"].waitForExistence(timeout: 10))
    }

    private func snap(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["OWNDESK_SCREENSHOTS"], !folder.isEmpty else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
