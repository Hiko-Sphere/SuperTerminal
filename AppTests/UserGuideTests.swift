import Foundation
import Testing
@testable import ApexTerminal

/// The in-app user guide (D-056).
///
/// A guide is documentation, so the temptation is to treat it as unverifiable prose. Most
/// of it is — but its *structure* is not: the three languages have to describe the same
/// app, every topic has to be reachable, and search has to find a topic by a word in its
/// body rather than only by its title. All of that is checkable, and all of it is the
/// part that breaks silently when a translation is updated.
@Suite struct UserGuideParsingTests {
    @Test("Topics are split on their markers, and the heading is the title")
    func parsesTopics() throws {
        let guide = try UserGuide("""
        <!-- topic: first -->
        ## The first thing

        A sentence about it.

        <!-- topic: second -->
        ## The second thing

        | Key | Meaning |
        | --- | --- |
        | ⌘D | Split |
        """)

        #expect(guide.topics.map(\.slug) == ["first", "second"])
        #expect(guide.topics[0].title == "The first thing")
        #expect(guide.topics[0].summary == "A sentence about it.")
        // A topic that opens with a table has no summary, and that must not be a crash or
        // a stray table cell pretending to be prose.
        #expect(guide.topics[1].summary.isEmpty)
        #expect(guide.topics[1].document.blocks.contains { if case .table = $0 { return true }; return false })
    }

    @Test("Search reads the body, not just the title")
    func searchesBodies() throws {
        let guide = try UserGuide("""
        <!-- topic: forwarding -->
        ## Port forwarding

        Unless the server sets GatewayPorts it can only bind 127.0.0.1.

        <!-- topic: keys -->
        ## Keys

        Generated in the Secure Enclave, or in the Keychain.
        """)

        // The word someone actually searches for is the one in the error they are staring
        // at, which is nowhere in any title.
        #expect(guide.topics(matching: "GatewayPorts").map(\.slug) == ["forwarding"])
        #expect(guide.topics(matching: "secure enclave").map(\.slug) == ["keys"], "search ignores case")
        #expect(guide.topics(matching: "  ").count == 2, "a blank query is not a filter")
        #expect(guide.topics(matching: "nothing here").isEmpty)
    }

    @Test("A malformed guide is reported rather than half-rendered")
    func rejectsMalformedGuides() {
        #expect(throws: UserGuideError.contentBeforeFirstTopic) {
            try UserGuide("Some prose with no topic marker above it.")
        }
        #expect(throws: UserGuideError.empty) {
            try UserGuide("\n\n")
        }
        #expect(throws: UserGuideError.topicWithoutHeading("orphan")) {
            try UserGuide("<!-- topic: orphan -->\nJust a paragraph.")
        }
        #expect(throws: UserGuideError.duplicateTopic("twice")) {
            try UserGuide("<!-- topic: twice -->\n## One\n<!-- topic: twice -->\n## Two")
        }
    }
}

/// What ships in the bundle, in all three languages.
@Suite struct UserGuideBundleTests {
    private static let languages = ["en", "zh-Hans", "zh-Hant"]

    private func guide(_ language: String) throws -> UserGuide {
        let bundle = Bundle(for: AppContainer.self)
        let url = try #require(bundle.url(forResource: "guide-\(language)", withExtension: "md"))
        return try UserGuide(String(contentsOf: url, encoding: .utf8))
    }

    @Test("Each language is bundled, parses, and says something in every topic",
          arguments: languages)
    func guideIsBundledAndSubstantial(language: String) throws {
        let english = try Dictionary(uniqueKeysWithValues: self.guide("en").topics.map { ($0.slug, $0) })
        let guide = try guide(language)
        #expect(guide.topics.count >= 15, "\(language) has only \(guide.topics.count) topics")
        for topic in guide.topics {
            #expect(!topic.title.isEmpty, "\(language)/\(topic.slug) has no title")
            #expect(!topic.document.blocks.isEmpty)
            #expect(!topic.searchText.contains("TODO"))
            #expect(!topic.searchText.contains("Lorem"))

            // Long enough to be an answer rather than a heading with a sentence under it —
            // measured against the same topic in English rather than against a flat
            // character count, because a character count is not comparable across scripts:
            // the Chinese guide says the same things in roughly 0.33 to 0.53 of the
            // characters, so a threshold that fits English passes a stub in Chinese and a
            // threshold that fits Chinese fails nothing at all. The ratio catches what
            // matters — a topic left untranslated, truncated, or reduced to a stub — and it
            // is stricter than the flat rule it replaces: 0.30 of the English length is a
            // higher bar for the long topics than 200 characters ever was.
            let reference = try #require(english[topic.slug], "\(topic.slug) is not in the English guide")
            #expect(topic.searchText.count > 100, "\(language)/\(topic.slug) says too little")
            if language != "en" {
                let ratio = Double(topic.searchText.count) / Double(reference.searchText.count)
                #expect(ratio > 0.30,
                        "\(language)/\(topic.slug) is \(topic.searchText.count) characters against \(reference.searchText.count) in English — too short to be the same topic")
            } else {
                #expect(topic.searchText.count > 200, "en/\(topic.slug) says too little")
            }
        }
    }

    @Test("The three languages describe the same app: same topics, same order")
    func languagesAgree() throws {
        let english = try guide("en").topics.map(\.slug)
        for language in Self.languages.dropFirst() {
            #expect(try guide(language).topics.map(\.slug) == english,
                    "\(language) does not have the same topics in the same order as English")
        }
    }

    @Test("Every topic has its own symbol", arguments: languages)
    func everyTopicHasASymbol(language: String) throws {
        for topic in try guide(language).topics {
            #expect(UserGuide.symbols[topic.slug] != nil, "no symbol for \(topic.slug)")
        }
        // And no symbol is left behind by a topic that was renamed or removed.
        let slugs = Set(try guide(language).topics.map(\.slug))
        for slug in UserGuide.symbols.keys {
            #expect(slugs.contains(slug), "\(slug) has a symbol but is in no guide")
        }
    }

    @Test("The guide describes the shortcuts the app actually has", arguments: languages)
    func shortcutsMatchTheApp(language: String) throws {
        let topic = try #require(try guide(language).topic(slug: "shortcuts"))
        // A guide that lists a key the app does not bind is worse than no guide: someone
        // presses it, nothing happens, and they conclude the app is broken. These are the
        // ones the table names; they are checked against the table the app routes.
        for shortcut in [AppShortcut.newConnection, .commandPalette, .splitRight, .closePane, .help] {
            let key = shortcut.input.uppercased()
            #expect(topic.searchText.uppercased().contains("⌘\(key)")
                        || topic.searchText.uppercased().contains("⌘\(key.lowercased())"),
                    "\(language) does not document ⌘\(key) (\(shortcut.rawValue))")
        }
    }

    @Test("The guide language follows the app's, and is one the guide exists in")
    func languageIsOneTheGuideExistsIn() {
        #expect(Self.languages.contains(UserGuide.documentLanguage))
        #expect(UserGuide.documentLanguage == LegalDocument.documentLanguage)
    }

    @Test("The bundled guide loads through the app's own path")
    func bundledLoads() throws {
        let guide = try UserGuide.bundled(bundle: Bundle(for: AppContainer.self))
        #expect(guide.topic(slug: "getting-started") != nil)
    }
}
