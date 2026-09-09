import XCTest

/// The in-app guide (D-056), through the interface.
///
/// The unit tests prove the guide parses and that the three languages agree. What they
/// cannot prove is that anyone can reach it: a guide that exists in the bundle and not in
/// the interface has not been shipped. So this opens it the way a person would, searches
/// for a word that appears only in the body of one topic, and reads that topic.
@MainActor
final class UserGuideUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTheGuideOpensFromSettingsAndSearchFindsATopicByItsBody() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ST_UITEST_RESET"] = "1"
        app.launch()

        app.buttons["Settings"].tap()
        let form = app.collectionViews["settings-form"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 10))

        let guide = app.buttons["settings-guide"].firstMatch
        var attempts = 0
        while !guide.isHittable, attempts < 10 { form.swipeUp(); attempts += 1 }
        XCTAssertTrue(guide.isHittable, "the guide should be reachable from Settings")
        guide.tap()

        let topics = app.collectionViews["help-topics"].firstMatch
        XCTAssertTrue(topics.waitForExistence(timeout: 10), "the topic list should appear")
        XCTAssertTrue(app.buttons["help-topic-getting-started"].waitForExistence(timeout: 5))

        // "GatewayPorts" is in the body of exactly one topic and in no title, which is the
        // case that matters: people search for the word in the error in front of them.
        // By its placeholder, not `firstMatch`: the connection list underneath the sheet
        // has a search field of its own, and it is the one that answers first.
        let field = app.searchFields["Search the guide"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // Return commits the search and puts the keyboard away, so the row underneath is
        // not under the keyboard when it is tapped.
        field.typeText("GatewayPorts\n")

        let forwarding = app.buttons["help-topic-forwarding"].firstMatch
        XCTAssertTrue(forwarding.waitForExistence(timeout: 5), "search should find a topic by its body")
        XCTAssertFalse(app.buttons["help-topic-getting-started"].exists, "and should filter the others out")

        forwarding.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "GatewayPorts")).firstMatch
                .waitForExistence(timeout: 10),
            "the topic body should render"
        )
    }
}
