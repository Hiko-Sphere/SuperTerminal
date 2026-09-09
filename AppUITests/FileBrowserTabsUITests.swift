import XCTest

/// Several remote folders open at once (D-071).
///
/// The browser used to be a sheet, so a second one replaced the first. This opens two against
/// the harness's own `sshd` and requires both to be there afterwards — which is the whole
/// claim, and the part of Phase 1.1 that was missing.
@MainActor
final class FileBrowserTabsUITests: XCTestCase {
    private lazy var app = XCUIApplication()

    // An override may add actor isolation when it is async, because the caller awaits the
    // hop; `setUpWithError()` cannot, and every line below touches `XCUIApplication` (D-068).
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

    /// Opens the seeded connection's files, from the list.
    private func openFiles() {
        let row = app.buttons.matching(identifier: "host-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
        row.press(forDuration: 1.0)
        let browse = app.buttons["host-files"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 5), "a connection offers to browse its files")
        browse.tap()
    }

    /// Back to the connection list, wherever the layout put it.
    private func returnToList() {
        if app.buttons["settings-open"].exists { return }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable { back.tap() }
        _ = app.buttons["settings-open"].waitForExistence(timeout: 10)
    }

    func testTwoFoldersCanBeOpenAtOnce() throws {
        openFiles()
        let path = app.descendants(matching: .any).matching(identifier: "files-path").firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 30), "the first browser should reach a directory")

        returnToList()
        openFiles()
        XCTAssertTrue(path.waitForExistence(timeout: 30), "the second browser should reach a directory too")

        // Both are still open, and both are reachable from the list. Before this change the
        // second replaced the first, and there was nothing to list.
        returnToList()
        let browsers = app.buttons.matching(identifier: "open-file-browser")
        XCTAssertEqual(browsers.count, 2, "both browsers should be listed as open")

        // And closing one leaves the other.
        browsers.element(boundBy: 0).swipeLeft()
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 5) { close.tap() }
        XCTAssertTrue(
            app.buttons.matching(identifier: "open-file-browser").count == 1,
            "closing one browser should leave the other open"
        )
    }
}
