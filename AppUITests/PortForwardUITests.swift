import XCTest

/// The port-forwarding screen, on a real connection (D-045).
///
/// The engine is proved against a real OpenSSH server in `STForwardingTests`, and the app's
/// own wiring — rules saved on a connection, started by a session — in
/// `PortForwardingTests`. What is left for this is the part only a person does: find the
/// screen, see the rule, start it, and see that it is running.
///
/// The rule is seeded rather than typed. Typing into the editor's fields is a keyboard
/// question, not a forwarding one, and this run cannot answer it reliably: a number pad
/// covers the fields below it and the simulator's focus behaviour makes that flaky. The
/// editor's own fields are checked for existence instead, and typing into forms is
/// exercised where it belongs, in `ServiceTokenUITests` and `BackupUITests`.
@MainActor
final class PortForwardUITests: XCTestCase {
    private lazy var app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        for key in ["ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
                    "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME",
                    "ST_UITEST_FORWARD_PORT"] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        try XCTSkipUnless(environment["ST_UITEST_SEED"] == "1", "needs the seeded connection")
        try XCTSkipUnless(environment["ST_UITEST_FORWARD_PORT"] != nil, "needs the seeded forward rule")
        app.launch()
    }

    func testAForwardCanBeStartedAndStoppedFromTheSession() throws {
        openForwards()

        let start = app.buttons["start-port-forward"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15), "the saved rule is listed with a way to start it")
        for _ in 0 ..< 40 where !start.isEnabled { usleep(250_000) }
        XCTAssertTrue(start.isEnabled, "a connected session can start a forward")
        start.tap()

        // Running means a listener really bound a port on this device; the row then offers
        // to stop it, and nothing else in the app can produce that state.
        let stop = app.buttons["stop-port-forward"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 20), "the forward should be running")
        stop.tap()
        XCTAssertTrue(app.buttons["start-port-forward"].firstMatch.waitForExistence(timeout: 10),
                      "stopping should offer to start it again")
    }

    func testTheEditorAsksForWhatEachKindOfForwardNeeds() throws {
        openForwards()
        app.buttons["add-port-forward"].firstMatch.tap()

        XCTAssertTrue(app.textFields["port-forward-listen-port"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["port-forward-target-host"].exists,
                      "a local forward needs somewhere to forward to")
        XCTAssertTrue(app.textFields["port-forward-target-port"].exists)
        XCTAssertFalse(app.buttons["save-port-forward"].firstMatch.isEnabled,
                       "an empty rule cannot be saved")

        // A dynamic forward has no destination to give, and the form says so by not asking.
        app.buttons["Dynamic (SOCKS5)"].firstMatch.tap()
        XCTAssertFalse(app.textFields["port-forward-target-host"].exists,
                       "a SOCKS proxy's clients choose their own destination")
        XCTAssertTrue(app.textFields["port-forward-listen-port"].exists)
    }

    private func openForwards() {
        let row = app.buttons.matching(identifier: "host-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
        row.tap()

        let menu = app.buttons["terminal-menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "the terminal should open")
        for _ in 0 ..< 60 where !menu.isHittable { usleep(250_000) }
        menu.tap()

        let forwards = app.buttons["terminal-menu-forwards"].firstMatch
        XCTAssertTrue(forwards.waitForExistence(timeout: 10), "the session menu offers port forwards")
        forwards.tap()
    }
}
