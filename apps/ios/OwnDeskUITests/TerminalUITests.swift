import XCTest

/// Opens a terminal on a real SSH server and runs a command in it. Needs a host and an SSH server,
/// so it skips unless they are named: scripts/test-ios-simulator.sh starts the headless agent and a
/// private sshd on this Mac, hands this test the pairing code, and adds this app's key to the server
/// when the test writes it out.
final class TerminalUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testOpenATerminalAndRunACommand() throws {
        let env = ProcessInfo.processInfo.environment
        guard let code = env["OWNDESK_PAIR_CODE"], !code.isEmpty,
              let port = env["OWNDESK_SSH_PORT"], let user = env["OWNDESK_SSH_USER"],
              let keyFile = env["OWNDESK_SSH_KEY_FILE"], let marker = env["OWNDESK_MARKER"]
        else { throw XCTSkip("no host or SSH server; run scripts/test-ios-simulator.sh") }

        // Pair, then read this iPhone's SSH key off the terminal sheet, as a person would to add it.
        let app = XCUIApplication()
        app.launchArguments = ["-OwnDeskReset", "YES", "-OwnDeskPairCode", code]
        app.launch()
        let screenButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mac-'")).firstMatch
        XCTAssertTrue(screenButton.waitForExistence(timeout: 60), "pairing did not finish")
        let fingerprint = String(screenButton.identifier.dropFirst("mac-".count))
        let terminalButton = app.buttons["terminal-\(fingerprint)"]
        XCTAssertTrue(terminalButton.exists, "no terminal button beside the Mac")
        terminalButton.tap()

        let key = app.staticTexts["ssh-public-key"]
        XCTAssertTrue(key.waitForExistence(timeout: 10), "the terminal sheet did not open")
        let line = (key.value as? String) ?? key.label
        XCTAssertTrue(line.hasPrefix("ecdsa-sha2-nistp256 "), "not an SSH key: \(line)")
        try line.write(toFile: keyFile, atomically: true, encoding: .utf8)
        snap("terminal-sheet")
        app.buttons["Cancel"].tap()
        app.terminate()
        // The script adds the key to the server within a moment of seeing the file.
        Thread.sleep(forTimeInterval: 2)

        // Straight into the terminal this time, at the address the private server listens on.
        let local = "127.0.0.1:\(env["OWNDESK_AGENT_PORT"] ?? "47610")"
        app.launchArguments = ["-OwnDeskAddress", local, "-OwnDeskTerminal", fingerprint,
                               "-OwnDeskSSHUser", user, "-OwnDeskSSHPort", port]
        app.launch()

        // The first terminal on this Mac: its host key is shown and trusted once.
        let trust = app.alerts.buttons["Trust"]
        XCTAssertTrue(trust.waitForExistence(timeout: 20), "no question about the host key")
        snap("terminal-trust")
        trust.tap()

        let terminal = app.descendants(matching: .any)["terminal-view"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        let message = app.staticTexts["terminal-message"]
        let connected = NSPredicate(format: "exists == false OR isHittable == false")
        expectation(for: connected, evaluatedWith: message)
        waitForExpectations(timeout: 20)

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
