import XCTest

/// tmux, through the interface, against a real tmux server (D-059).
///
/// The unit tests prove the protocol and the session; this proves the part they cannot —
/// that a person can open a connection marked for tmux and end up looking at a shell
/// running inside it, with tmux's own arrangement on screen.
@MainActor
final class TmuxUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            !(ProcessInfo.processInfo.environment["ST_UITEST_TMUX_PORT"] ?? "").isEmpty,
            "run scripts/ui-terminal-e2e.sh with Docker running to provide a tmux server"
        )
    }

    func testOpeningATmuxConnectionShowsAPaneRunningAShell() throws {
        // Every variable the app reads, handed over explicitly. The app is a separate
        // process and inherits none of the runner's environment — measured: passing only
        // the tmux ones left the app with no seed at all, so it kept the connections from
        // the previous run and the tmux one never appeared.
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        for key in [
            "ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
            "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME",
            "ST_UITEST_TMUX_PORT", "ST_UITEST_TMUX_USER", "ST_UITEST_TMUX_PASSWORD",
        ] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        app.launch()

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "tmux Test Server")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the seeded tmux connection should be listed")
        row.tap()

        // The pane is a real terminal with a real shell in it, so what proves it arrived is
        // the shell's own prompt — not a spinner, and not the pane's frame.
        let pane = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "tmux-pane-")
        ).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 60), "a tmux pane should appear")

        let prompt = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "$", "$")
        ).firstMatch
        _ = prompt.waitForExistence(timeout: 30)

        // And tmux's own commands are offered: a menu that lists windows and can split.
        let menu = app.buttons["tmux-menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the tmux menu should be in the toolbar")
        menu.tap()
        XCTAssertTrue(app.buttons["tmux-split-right"].waitForExistence(timeout: 5))
        app.buttons["tmux-split-right"].tap()

        // Splitting is tmux's, and the second pane must appear because tmux said so.
        let panes = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tmux-pane-"))
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, panes.count < 2 { usleep(300_000) }
        XCTAssertEqual(panes.count, 2, "the split should show two panes")
    }
}
