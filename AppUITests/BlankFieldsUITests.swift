import XCTest

/// D-024 end to end against the harness's real OpenSSH server: the hostname field
/// carries the port, the port field is blank, the user name is blank — and the
/// connection asks for the user name when it opens, then reaches the shell.
@MainActor
final class BlankFieldsUITests: XCTestCase {
    private lazy var app = XCUIApplication()

    // An override may *add* actor isolation when it is async, because the caller awaits
    // the hop; `setUpWithError()` cannot, and every line below touches `XCUIApplication`,
    // which is the main actor's (D-068).
    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        for key in ["ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
                    "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME"] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        try XCTSkipUnless(environment["ST_UITEST_SEED"] == "1", "needs the seeded connection")
        app.launch()
    }

    /// Replaces a field's text with delete keys, one per character. Neither the edit
    /// menu (a long press away, and slow to appear) nor ⌘A works everywhere: the port
    /// field uses a number pad, which has no ⌘A at all.
    private func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let current = (field.value as? String) ?? ""
        if current != field.placeholderValue, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        if !text.isEmpty { field.typeText(text) }
        // The field is the evidence: a blank one still reads as its placeholder.
        let expected = text.isEmpty ? (field.placeholderValue ?? "") : text
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, (field.value as? String) != expected { usleep(150_000) }
        XCTAssertEqual(field.value as? String, expected, "the field should hold exactly what was typed")
    }

    func testAddressWithPortBlankPortAndBlankUserNameConnect() throws {
        let environment = ProcessInfo.processInfo.environment
        let host = try XCTUnwrap(environment["ST_UITEST_HOST"])
        let port = try XCTUnwrap(environment["ST_UITEST_PORT"])
        let user = try XCTUnwrap(environment["ST_UITEST_USER"])
        let name = environment["ST_UITEST_NAME"] ?? "Test Server"

        let row = app.buttons.matching(identifier: "host-row")
            .matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
        row.press(forDuration: 1.0)
        let edit = app.buttons["Edit Connection"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Connection"].waitForExistence(timeout: 5))

        // The address as people paste it, the port field left blank, no user name.
        replace(app.textFields["hostname"], with: "\(host):\(port)")
        replace(app.textFields["port"], with: "")
        replace(app.textFields["username"], with: "")
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled, "a blank user name is allowed")
        save.tap()
        XCTAssertTrue(app.navigationBars["Edit Connection"].waitForNonExistence(timeout: 5))

        // The row shows host:port with no user, because the port is not the default.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !row.label.contains("\(host):\(port)") { usleep(200_000) }
        XCTAssertTrue(row.label.contains("\(host):\(port)"), "the address should be host:port; label was: \(row.label)")
        XCTAssertFalse(row.label.contains("@"), "no user name is saved, so none is shown")

        // Opening asks for the user name, then reaches the shell over the real server.
        row.tap()
        let prompt = app.textFields["prompt-username"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "a connection without a user name asks for one")
        prompt.tap()
        prompt.typeText(user)
        app.buttons["Continue"].firstMatch.tap()
        let terminal = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Terminal for")).firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "the shell should open after the user name is given")
        XCTAssertTrue(app.buttons["Session"].waitForExistence(timeout: 10))
    }
}
