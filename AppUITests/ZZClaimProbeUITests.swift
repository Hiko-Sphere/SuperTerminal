import XCTest

/// TEMPORARY probe: does tapping a session in the list switch the terminal shown?
@MainActor
final class ZZClaimProbeUITests: XCTestCase {
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

    private func openFromHostRow() {
        var row = app.buttons.matching(identifier: "host-row").firstMatch
        if !row.waitForExistence(timeout: 3) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            row = app.buttons.matching(identifier: "host-row").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
        }
        for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
        row.tap()
        XCTAssertTrue(terminal.waitForExistence(timeout: 30))
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, app.activityIndicators.firstMatch.exists { usleep(200_000) }
    }

    func testTappingAnOpenSessionRowSwitchesTheTerminalShown() throws {
        openFromHostRow()
        app.typeText("printf 'ALPHA_%s\\n' OK\n")
        XCTAssertTrue(screen(containing: "ALPHA_OK").contains("ALPHA_OK"), "first session should take typing")

        openFromHostRow()
        app.typeText("printf 'BETA_%s\\n' OK\n")
        let second = screen(containing: "BETA_OK")
        XCTAssertTrue(second.contains("BETA_OK"), "second session should take typing")
        XCTAssertFalse(second.contains("ALPHA_OK"), "and it is a different session")

        // Back to the list if the layout pushed away from it.
        var rows = app.buttons.matching(identifier: "open-session")
        if rows.count < 2 {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists, back.isHittable { back.tap() }
            rows = app.buttons.matching(identifier: "open-session")
        }
        XCTAssertEqual(rows.count, 2, "both open sessions should be listed")

        let first = rows.element(boundBy: 0)
        for _ in 0 ..< 20 where !first.isHittable { usleep(150_000) }
        XCTAssertTrue(first.isHittable, "the first session row should be tappable")
        first.tap()

        let shown = screen(containing: "ALPHA_OK", timeout: 15)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "After tapping the first session row"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(shown.contains("ALPHA_OK"), "tapping the first session should bring it back; screen was: \(shown.suffix(400))")
        XCTAssertFalse(shown.contains("BETA_OK"), "and not still the session it switched away from")

        // And typing must now land in the session on screen, not the one it left.
        app.typeText("printf 'AFTER_%s\\n' OK\n")
        let after = screen(containing: "AFTER_OK", timeout: 15)
        XCTAssertTrue(after.contains("AFTER_OK"), "typing should reach the session tapped back to; screen: \(after.suffix(400))")
        XCTAssertTrue(after.contains("ALPHA_OK"), "and it is still the first session")
    }
}
