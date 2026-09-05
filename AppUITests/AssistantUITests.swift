import XCTest

/// The assistant (D-020) on a machine with no eligible on-device model and no provider
/// key: it says so and offers Settings, rather than pretending. Settings carries the
/// provider fields. What an answer looks like needs a key the owner supplies and is a
/// hardware check in docs/RELEASE.md.
@MainActor
final class AssistantUITests: XCTestCase {
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

    func testAssistantSaysWhyItCannotAnswerAndOffersSettings() throws {
        // The row itself: the "Reopen Local Test Server" offer from a previous run carries
        // the same name and sits above the list.
        let host = app.buttons.matching(identifier: "host-row")
            .matching(NSPredicate(format: "label CONTAINS %@", "Local Test Server")).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        host.tap()
        let terminal = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Terminal for")).firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30))
        app.buttons["Session"].tap()
        let item = app.buttons["Assistant…"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the Session menu should offer the assistant")
        item.tap()
        let sheet = app.descendants(matching: .any).matching(identifier: "assistant-sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the assistant sheet should open")
        // A seeded run stores no provider key, so the sheet has either the on-device model —
        // a simulator on a Mac with Apple Intelligence reports it available — or nothing.
        // Either way it must be honest: an answer from the model, or the reason and the way
        // to Settings.
        let engine = (sheet.value as? String) ?? ""
        if engine == "onDevice" {
            let question = app.descendants(matching: .any).matching(identifier: "assistant-question").firstMatch
            XCTAssertTrue(question.waitForExistence(timeout: 5))
            question.tap()
            question.typeText("list the files in the current folder")
            app.descendants(matching: .any).matching(identifier: "assistant-ask").firstMatch.tap()
            let answer = app.descendants(matching: .any).matching(identifier: "assistant-answer").firstMatch
            let unavailable = app.descendants(matching: .any).matching(identifier: "assistant-unavailable").firstMatch
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline, !answer.exists, !unavailable.exists {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            if answer.exists {
                XCTAssertFalse(answer.label.isEmpty, "the answer should carry text")
                XCTContext.runActivity(named: "The on-device model answered") { _ in }
            } else {
                // The model said it was available and then could not run — this Mac's
                // simulator does that. The sheet must now say so, name the failure, and
                // point at Settings rather than fail the same way on the next question.
                XCTAssertTrue(unavailable.exists, "the on-device model should answer within two minutes, or the sheet must say why it cannot")
                XCTAssertEqual(sheet.value as? String, "unavailable", "after a failure the sheet reports the honest state")
                XCTAssertTrue(unavailable.label.contains("on-device model"), "the reason names the model: \(unavailable.label)")
                XCTAssertTrue(app.buttons["Open Settings"].exists, "and offers the way to a provider")
                XCTContext.runActivity(named: "The on-device model failed and the sheet reported it: \(unavailable.label)") { _ in }
            }
        } else {
            XCTAssertEqual(engine, "unavailable", "with no key stored only the on-device model can be available")
            let unavailable = app.descendants(matching: .any).matching(identifier: "assistant-unavailable").firstMatch
            XCTAssertTrue(unavailable.waitForExistence(timeout: 5), "with nothing configured the assistant must say so")
            XCTAssertTrue(app.buttons["Open Settings"].exists)
            app.buttons["Open Settings"].tap()
            let endpoint = app.textFields["assistant-endpoint"]
            XCTAssertTrue(endpoint.waitForExistence(timeout: 5), "Settings should carry the provider fields")
            XCTAssertEqual(endpoint.value as? String, "https://api.openai.com/v1", "the common default is filled in")
        }
    }
}
