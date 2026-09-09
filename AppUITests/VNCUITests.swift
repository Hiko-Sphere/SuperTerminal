import XCTest

/// A remote screen end to end (D-022, D-027): the harness runs LibVNCServer behind the
/// local OpenSSH server; the screen is its own saved connection that names the SSH one it
/// travels through, and the app reaches it through a `direct-tcpip` channel, decodes the
/// desktop, and its taps and keys arrive in the server's log.
@MainActor
final class VNCUITests: XCTestCase {
    private lazy var app = XCUIApplication()
    private var logPath = ""

    // An override may *add* actor isolation when it is async, because the caller awaits
    // the hop; `setUpWithError()` cannot, and every line below touches `XCUIApplication`,
    // which is the main actor's (D-068).
    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        for key in ["ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
                    "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME", "ST_UITEST_VNC_PORT"] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        try XCTSkipUnless(environment["ST_UITEST_SEED"] == "1", "needs the seeded connection")
        try XCTSkipUnless(environment["ST_UITEST_VNC_PORT"] != nil,
                          "needs the harness's screen server, which needs LibVNCServer (brew install libvncserver)")
        logPath = try XCTUnwrap(environment["ST_UITEST_VNC_LOG"])
        app.launch()
    }

    private func serverLog() -> String {
        (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    }

    private func waitForLog(containing needle: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if serverLog().contains(needle) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return serverLog().contains(needle)
    }

    func testOpeningTheScreenOverSSHShowsTheDesktopAndDeliversInput() throws {
        // A screen is its own row, in its own section — not an action on an SSH connection.
        let row = app.buttons.matching(identifier: "screen-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the saved screen should be in the list")
        XCTAssertTrue(row.label.contains("through"), "the row says which SSH connection it goes through; label was: \(row.label)")
        for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
        row.tap()

        let screen = app.descendants(matching: .any).matching(identifier: "vnc-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "the screen view should appear")
        // The name and size come from the server's ServerInit, through the SSH channel.
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, !((screen.value as? String) ?? "").contains("320 × 200") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(screen.value as? String, "ApexTerminal test desktop, 320 × 200",
                       "the desktop's own name and size, decoded from a real server over SSH")
        XCTAssertTrue(serverLog().contains("client connected"), "the server saw the client")

        // A tap is a click: the server logs the press and the release.
        screen.tap()
        XCTAssertTrue(waitForLog(containing: "pointer 1 ", timeout: 10), "the tap should reach the server as a button press; log:\n\(serverLog())")
        XCTAssertTrue(waitForLog(containing: "pointer 0 ", timeout: 5), "and be released")

        // The key row sends keys a touch keyboard cannot; Escape is 0xff1b in X11's vocabulary.
        let escape = app.buttons["vnc-key-escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 5), "the key row should be up once connected")
        escape.tap()
        XCTAssertTrue(waitForLog(containing: "key down 0xff1b", timeout: 10), "Escape should arrive; log:\n\(serverLog())")
        XCTAssertTrue(waitForLog(containing: "key up 0xff1b", timeout: 5))

        // Ctrl latched, then a key: Control goes down before it and up after it.
        app.buttons["vnc-modifier-ctrl"].tap()
        app.buttons["vnc-key-tab"].tap()
        XCTAssertTrue(waitForLog(containing: "key down 0xff09", timeout: 10))
        let log = serverLog()
        let controlDown = log.range(of: "key down 0xffe3")
        let tabDown = log.range(of: "key down 0xff09")
        XCTAssertNotNil(controlDown, "Control should have gone down")
        if let controlDown, let tabDown {
            XCTAssertTrue(controlDown.lowerBound < tabDown.lowerBound, "the modifier is pressed before the key")
        }
        XCTAssertTrue(log.contains("key up 0xffe3"), "and released after it")
    }

    /// A screen is configured on its own (D-027): its own editor, reached from its own
    /// row, with the SSH connection it uses as one field among its own.
    func testAScreenIsEditedOnItsOwnAndTheSSHEditorHasNoScreenSection() throws {
        let row = app.buttons.matching(identifier: "screen-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
        row.press(forDuration: 1.0)
        let edit = app.buttons["Edit Screen"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "a screen row offers to edit the screen")
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["screen-address"].exists, "the screen has its own address")
        XCTAssertTrue(app.textFields["screen-port"].exists, "and its own port")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "screen-ssh-host").firstMatch.exists,
                      "and names the SSH connection it travels through")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Edit Screen"].waitForNonExistence(timeout: 5))

        // The SSH editor no longer carries any of it.
        let host = app.buttons.matching(identifier: "host-row").firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        for _ in 0 ..< 20 where !host.isHittable { usleep(150_000) }
        host.press(forDuration: 1.0)
        let editHost = app.buttons["Edit Connection"].firstMatch
        XCTAssertTrue(editHost.waitForExistence(timeout: 5))
        editHost.tap()
        XCTAssertTrue(app.navigationBars["Edit Connection"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "vnc-enabled").firstMatch.exists,
                       "the SSH editor has no screen sharing section any more")
        XCTAssertFalse(app.buttons["Open Screen"].exists)
    }

    /// A screen that signs in to an account needs a user name as well as a password
    /// (D-031), and both may be left empty — most screens have neither.
    func testAScreenKeepsAnOptionalUserName() throws {
        func openEditor() {
            let row = app.buttons.matching(identifier: "screen-row").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
            row.press(forDuration: 1.0)
            let edit = app.buttons["Edit Screen"].firstMatch
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            edit.tap()
            XCTAssertTrue(app.navigationBars["Edit Screen"].waitForExistence(timeout: 5))
        }

        openEditor()
        let field = app.textFields["screen-username"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the screen has a user name field")
        XCTAssertEqual(field.value as? String, "User name (optional)",
                       "and it starts empty, because most screens have no account")
        field.tap()
        field.typeText("screen-account")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Edit Screen"].waitForNonExistence(timeout: 5))

        // It is still there when the screen is opened again, so it was actually stored.
        openEditor()
        XCTAssertEqual(app.textFields["screen-username"].value as? String, "screen-account")
        app.buttons["Cancel"].firstMatch.tap()
    }
}
