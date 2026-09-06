import Foundation
import Testing
@testable import SuperTerminal

/// What the tour is, independently of how it is laid out (D-033).
@Suite struct TutorialTests {
    @Test("Every page teaches something, in a stable order, with no placeholder text")
    func pages() {
        let pages = TutorialPage.all
        #expect(pages.count == 6)
        // The ids are the order and the TabView's tags; a gap or a repeat would page to
        // the wrong screen rather than fail visibly.
        #expect(pages.map(\.id) == Array(0 ..< pages.count))
        #expect(Set(pages.map(\.illustration)).count == pages.count, "each page has its own picture")

        for page in pages {
            #expect(!page.title.isEmpty)
            #expect(!page.symbol.isEmpty)
            // Long enough to actually say something: a tour page of three words is a slide.
            #expect(page.body.count > 80, "\(page.title) says too little to be worth a page")
            #expect(!page.body.contains("TODO") && !page.body.contains("Lorem"))
        }
    }

    @Test("The tour is off by default and stays off once it has been seen")
    @MainActor func setting() {
        let defaults = UserDefaults(suiteName: "tutorial-tests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.hasSeenTutorial, "a fresh install has not seen it, so it is shown")

        settings.hasSeenTutorial = true
        // Survives a relaunch: the whole point is that it is shown once.
        let reopened = AppSettings(defaults: defaults)
        #expect(reopened.hasSeenTutorial)

        // And "Delete all data" puts it back, because that is a fresh start.
        reopened.resetToDefaults()
        #expect(!reopened.hasSeenTutorial)
    }
}
