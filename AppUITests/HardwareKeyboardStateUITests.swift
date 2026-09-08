import XCTest

/// Typing after something else has held the keyboard (D-025).
///
/// The existing typing tests all wait for the software keyboard before they type, so they
/// only ever exercise the state a phone is in. With a hardware keyboard there is no
/// software keyboard to wait for and none to disappear: when a sheet or a search field
/// takes first-responder status and nothing gives it back, typing simply stops, with
/// nothing on screen to say so. These tests type without ever asking for a keyboard, and
/// after each thing that takes focus away.
@MainActor
final class HardwareKeyboardStateUITests: XCTestCase {
    private lazy var app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        for key in ["ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
                    "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME"] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        try XCTSkipUnless(environment["ST_UITEST_SEED"] == "1", "needs the seeded connection")
        app.launch()
    }

    private var terminal: XCUIElement {
        app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Terminal for")).firstMatch
    }

    private func openTerminal() {
        let row = app.buttons.matching(identifier: "host-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
        row.tap()
        XCTAssertTrue(terminal.waitForExistence(timeout: 30))
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, app.activityIndicators.firstMatch.exists { usleep(200_000) }
        // This simulator discards the first modified key press delivered to a screen, and
        // the terminal is the screen these tests act on. ⌘C is spent on it here — the
        // terminal consumes it and copies nothing, because nothing is selected — so the
        // first shortcut a test sends is the first one that counts. See
        // `XCUIApplication.primeModifierKeysInTerminal` for what was measured.
        app.primeModifierKeysInTerminal()
    }

    private func screen(containing needle: String, timeout: TimeInterval = 20) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""
        while Date() < deadline {
            latest = terminal.value as? String ?? ""
            if latest.contains(needle) { return latest }
            usleep(200_000)
        }
        return latest
    }

    /// Deliberately does not tap the terminal first and never waits for `app.keyboards`:
    /// the point is that the terminal is ready to type into without being asked.
    private func type(_ text: String) {
        app.typeText(text)
    }

    func testTypingWorksAfterEveryThingThatTakesTheKeyboardAway() throws {
        openTerminal()

        // A baseline, with nothing having stolen focus yet.
        type("printf 'BASE_%s\\n' OK\n")
        XCTAssertTrue(screen(containing: "BASE_OK").contains("BASE_OK"), "typing should reach the shell when the terminal opens")

        // The find bar takes the keyboard and closes without handing it back. It is
        // closed with its own button: XCUITest does not deliver Escape to a focused text
        // field on this simulator, which D-018 measured and HardwareKeyboardUITests pins.
        app.typeKey("f", modifierFlags: .command)
        let findField = app.textFields["find-query"]
        XCTAssertTrue(findField.waitForExistence(timeout: 5), "⌘F should open the find bar")
        app.buttons["find-close"].firstMatch.tap()
        XCTAssertTrue(findField.waitForNonExistence(timeout: 5), "the find bar should close")
        type("printf 'FIND_%s\\n' OK\n")
        XCTAssertTrue(screen(containing: "FIND_OK").contains("FIND_OK"), "typing should reach the shell after the find bar closes")

        // The command palette's own field takes it too. It is a sheet, so it is dismissed
        // the way the other sheet tests dismiss one.
        app.typeKey("k", modifierFlags: .command)
        let palette = app.textFields["palette-query"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "⌘K should open the palette")
        // A sheet is dismissed by dragging it down from its own top edge.
        let sheetTop = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        sheetTop.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(palette.waitForNonExistence(timeout: 10), "the palette should close")
        type("printf 'PALETTE_%s\\n' OK\n")
        XCTAssertTrue(screen(containing: "PALETTE_OK").contains("PALETTE_OK"), "typing should reach the shell after the palette closes")

        // And a whole sheet, presented and dismissed.
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))
        type("printf 'SHEET_%s\\n' OK\n")
        XCTAssertTrue(screen(containing: "SHEET_OK").contains("SHEET_OK"), "typing should reach the shell after a sheet is dismissed")
    }

    /// On iPad the detail column keeps one terminal view for every session, so switching
    /// sessions used to leave the keyboard wired to the session opened first: the second
    /// terminal drew its prompt and every keystroke went to the first shell.
    func testTypingFollowsTheSessionOnScreen() throws {
        openTerminal()
        type("printf 'FIRST_%s\\n' OK\n")
        XCTAssertTrue(screen(containing: "FIRST_OK").contains("FIRST_OK"))

        // A second session to the same server. On a phone the list is behind the
        // terminal; on an iPad the sidebar is already there.
        var row = app.buttons.matching(identifier: "host-row").firstMatch
        if !row.waitForExistence(timeout: 2) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            row = app.buttons.matching(identifier: "host-row").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
        }
        for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
        row.tap()
        XCTAssertTrue(terminal.waitForExistence(timeout: 30))
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, app.activityIndicators.firstMatch.exists { usleep(200_000) }

        type("printf 'SECOND_%s\\n' OK\n")
        let shown = screen(containing: "SECOND_OK")
        XCTAssertTrue(shown.contains("SECOND_OK"), "typing should reach the session on screen; the screen showed: \(shown.suffix(300))")
        XCTAssertFalse(shown.contains("FIRST_OK"), "and this is the second session, not the first")
    }
}
