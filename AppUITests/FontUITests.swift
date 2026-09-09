import XCTest

/// The font choice, through the interface and out to the server (D-063).
///
/// The claim worth testing is not that a picker exists but that changing the font changes
/// the *grid*: fewer rows fit, the app tells the server, and the remote `stty` agrees. A
/// font setting that did not reach the far side would leave every full-screen program
/// drawing to the wrong size.
@MainActor
final class FontUITests: XCTestCase {
    private lazy var app: XCUIApplication = {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        for key in [
            "ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
            "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME",
        ] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        app.launch()
        return app
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ST_UITEST_SEED"] == "1",
            "run scripts/ui-terminal-e2e.sh to provide a server"
        )
    }

    func testChangingTheLineHeightChangesWhatTheServerIsTold() throws {
        // Open the seeded connection and read the size the server sees now.
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Local Test Server")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()

        let terminal = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Terminal for")
        ).firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30))
        if terminal.isHittable { terminal.tap() }

        let before = rowsReportedByTheServer(terminal, marker: "SIZE_ONE")
        XCTAssertGreaterThan(before, 0, "the server should report a size")

        // Back to the list first: on a phone the terminal is pushed over it, and Settings
        // lives on the list's own toolbar.
        if !app.buttons["settings-open"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.buttons["settings-open"].waitForExistence(timeout: 10))

        // Make each line taller. Fewer rows fit in the same view, and the server has to be
        // told — the app sends a window-change request when the grid changes.
        app.buttons["settings-open"].tap()
        let stepper = app.steppers["settings-line-height"]
        var attempts = 0
        while !stepper.exists, attempts < 12 { app.swipeUp(); attempts += 1 }
        XCTAssertTrue(stepper.waitForExistence(timeout: 5), "Settings should offer a line height")

        // The sample is the only place the choice can be judged before leaving Settings,
        // so it has to answer to the same setting the grid does: taller rows, taller sample.
        let sample = app.descendants(matching: .any).matching(identifier: "settings-font-sample").firstMatch
        XCTAssertTrue(sample.waitForExistence(timeout: 5), "Settings should show a font sample")
        let sampleBefore = sample.frame.height
        XCTAssertGreaterThan(sampleBefore, 0)

        for _ in 0 ..< 8 { stepper.buttons.element(boundBy: 1).tap() }

        XCTAssertGreaterThan(
            sample.frame.height,
            sampleBefore,
            "the sample should grow with the line height it is previewing"
        )
        app.buttons["Done"].firstMatch.tap()

        // And back into the same session, which is still open.
        if !terminal.exists {
            let openSession = app.buttons.matching(identifier: "open-session").firstMatch
            if openSession.waitForExistence(timeout: 5) {
                openSession.tap()
            } else {
                app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Local Test Server"))
                    .firstMatch.tap()
            }
        }
        XCTAssertTrue(terminal.waitForExistence(timeout: 30))

        let after = rowsReportedByTheServer(terminal, marker: "SIZE_TWO")
        XCTAssertGreaterThan(after, 0, "the server should report a size after the change")
        XCTAssertLessThan(after, before, "taller lines mean fewer rows, and the server should know")
    }

    /// Asks the remote shell how big it thinks the terminal is.
    private func rowsReportedByTheServer(_ terminal: XCUIElement, marker: String) -> Int {
        if terminal.isHittable { terminal.tap() }
        terminal.typeText("printf '\(marker)_%s\\n' $(stty size | cut -d' ' -f1)\n")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let screen = terminal.value as? String ?? ""
            // The marker is assembled by printf, so the echo of the command cannot match it.
            for line in screen.split(separator: "\n") where line.contains("\(marker)_") {
                let digits = line.split(separator: "_").last.map { $0.prefix { $0.isNumber } } ?? ""
                if let rows = Int(digits), rows > 0 { return rows }
            }
            usleep(200_000)
        }
        return 0
    }
}
