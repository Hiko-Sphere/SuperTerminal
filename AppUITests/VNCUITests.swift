import XCTest

/// A remote screen end to end (D-022): the harness runs LibVNCServer behind the local
/// OpenSSH server; the app reaches it through a `direct-tcpip` channel on the SSH
/// connection, decodes the desktop, and its taps and keys arrive in the server's log.
@MainActor
final class VNCUITests: XCTestCase {
    private lazy var app = XCUIApplication()
    private var logPath = ""

    override func setUpWithError() throws {
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
        let host = app.buttons.matching(identifier: "host-row")
            .matching(NSPredicate(format: "label CONTAINS %@", "Local Test Server")).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        host.press(forDuration: 1.0)
        let open = app.buttons["Open Screen"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "a connection with screen sharing offers Open Screen")
        open.tap()

        let screen = app.descendants(matching: .any).matching(identifier: "vnc-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "the screen view should appear")
        // The name and size come from the server's ServerInit, through the SSH channel.
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, !((screen.value as? String) ?? "").contains("320 × 200") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(screen.value as? String, "SuperTerminal test desktop, 320 × 200",
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
}
