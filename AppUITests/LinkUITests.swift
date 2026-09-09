import XCTest

/// Links, through the interface (D-061).
///
/// The property under test is the one that matters: a link that carries a command shows
/// exactly what it would run and does nothing until somebody says yes. Refusing must leave
/// no trace, and allowing must actually run it — on the real server the harness started,
/// so "it ran" means the shell printed something.
@MainActor
final class LinkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ST_UITEST_SEED"] == "1",
            "run scripts/ui-terminal-e2e.sh to provide a server"
        )
    }

    private func launch(withLink link: String) -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        for key in [
            "ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
            "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME",
        ] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        app.launchEnvironment["ST_UITEST_OPEN_URL"] = link
        app.launch()
        return app
    }

    /// `apexterminal://run?host=Local Test Server&command=printf 'LINK_%s\n' OK`
    private let runLink =
        "apexterminal://run?host=Local%20Test%20Server&command=printf%20%27LINK_%25s%5Cn%27%20OK"

    func testALinkWithACommandAsksFirstAndRunsNothingWhenRefused() throws {
        let app = launch(withLink: runLink)

        let sheet = app.otherElements["link-confirmation"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "a link carrying a command must ask")

        // The command is shown verbatim: a question that does not say what it is asking
        // about trains people to say yes.
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "LINK_")).firstMatch
                .waitForExistence(timeout: 5),
            "the command should be on screen"
        )

        app.buttons["link-cancel"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))

        // Nothing opened, so nothing ran. The connection list is what a refusal leaves.
        XCTAssertTrue(app.buttons["add-connection"].waitForExistence(timeout: 10))
        let terminal = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Terminal for")
        ).firstMatch
        XCTAssertFalse(terminal.exists, "refusing a link must not open a session")
    }

    func testAllowingTheLinkRunsItOnTheServer() throws {
        let app = launch(withLink: runLink)

        let sheet = app.otherElements["link-confirmation"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20))
        app.buttons["link-approve"].tap()

        // The shell's own output is the proof, read the way the other terminal tests read
        // it: the terminal's accessibility value is the rendered screen. The marker is
        // assembled by printf so it cannot match the echo of the command that produced it.
        let terminal = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Terminal for")
        ).firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "the link should have opened the session")

        let deadline = Date().addingTimeInterval(60)
        var screen = ""
        while Date() < deadline, !screen.contains("LINK_OK") {
            screen = terminal.value as? String ?? ""
            usleep(200_000)
        }
        XCTAssertTrue(screen.contains("LINK_OK"), "the command should have run on the server; screen was:\n\(screen)")
    }
}
