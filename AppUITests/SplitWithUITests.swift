import XCTest

/// Putting something *else* in the other half of a split (D-074).
///
/// ⌘D means "another shell on this same server", which is right for a second shell and wrong
/// for everything else people put side by side. This drives the other path: the picker, the
/// choice, and the pane that follows from it — against the harness's own `sshd`, so the second
/// pane is a real session on a real server rather than a rectangle.
@MainActor
final class SplitWithUITests: XCTestCase {
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

    /// Scrolls the picker until the row is there.
    ///
    /// On a phone the sheet opens at its medium detent, so the last rows are below the fold —
    /// and a row below the viewport is not merely off-screen, it is not in the accessibility
    /// tree at all. The same thing the Settings tests learned in D-068.
    private func pickerRow(_ identifier: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        var attempts = 0
        while !element.exists, attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        _ = element.waitForExistence(timeout: 5)
        return element
    }

    func testSplittingOffersEverySortOfThingAndOpensTheChosenOne() throws {
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Local Test Server")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()

        let terminals = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Terminal for"))
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, terminals.count < 1 { usleep(300_000) }
        XCTAssertEqual(terminals.count, 1, "one terminal to begin with")

        // Reachable without a keyboard: a feature only ⌥⌘D can start is one most people
        // never find.
        app.buttons["terminal-menu"].firstMatch.tap()
        let splitWith = app.buttons["terminal-menu-split-with"]
        XCTAssertTrue(splitWith.waitForExistence(timeout: 5), "the session menu should offer Split With…")
        splitWith.tap()

        let picker = app.descendants(matching: .any).matching(identifier: "split-target-picker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "choosing a split should raise the picker")

        // The whole point of the picker: the other half is not necessarily this same server.
        // A server that is not saved yet, and a screen, are both offered here.
        XCTAssertTrue(
            pickerRow("split-target-add-connection").exists,
            "a server that is not in the list yet has to be reachable from here"
        )
        XCTAssertTrue(
            pickerRow("split-target-add-screen").exists,
            "and so does a screen"
        )
        XCTAssertTrue(
            app.searchFields.firstMatch.exists,
            "the picker should be searchable, or a long list is unusable"
        )

        // Choose the saved connection explicitly — the deliberate act ⌘D cannot express.
        let choice = app.buttons.matching(identifier: "split-target-row")
            .containing(NSPredicate(format: "label CONTAINS %@", "Local Test Server")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "the saved connection should be offered")
        choice.tap()

        let paneCount = app.descendants(matching: .any).matching(identifier: "pane-count").firstMatch
        XCTAssertTrue(paneCount.waitForExistence(timeout: 10))
        let paneDeadline = Date().addingTimeInterval(45)
        while Date() < paneDeadline, (paneCount.value as? String) != "2" { usleep(300_000) }
        XCTAssertEqual(paneCount.value as? String, "2", "choosing should have divided the pane")

        let bothDeadline = Date().addingTimeInterval(45)
        while Date() < bothDeadline, terminals.count < 2 { usleep(300_000) }
        XCTAssertEqual(terminals.count, 2, "and the chosen connection should be running in the new pane")
    }
}
