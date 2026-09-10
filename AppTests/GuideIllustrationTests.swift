import Foundation
import Testing

@testable import ApexTerminal

/// The pictures in the user guide, and the marker that puts them there (D-080).
///
/// The guide is prose in three files and the drawings are Swift, so the only thing joining
/// them is a name inside an HTML comment. Nothing at build time checks that a marker names a
/// picture that exists — the renderer draws nothing for a name it does not know, which is the
/// right behaviour on screen and a silent one. These tests are what makes the join real: a
/// typo in a marker fails here rather than removing a picture nobody notices is gone.
@Suite("Illustrations in the guide")
struct GuideIllustrationTests {
    private static let languages = ["en", "zh-Hans", "zh-Hant"]

    private func source(_ language: String) throws -> String {
        let bundle = Bundle(for: AppContainer.self)
        let url = try #require(bundle.url(forResource: "guide-\(language)", withExtension: "md"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func guide(_ language: String) throws -> UserGuide {
        try UserGuide(source(language))
    }

    /// Every illustration in a language, by the topic it belongs to.
    private func illustrations(_ language: String) throws -> [String: [String]] {
        var found: [String: [String]] = [:]
        for topic in try guide(language).topics {
            let names = topic.document.blocks.compactMap { block -> String? in
                if case let .illustration(name) = block { return name }
                return nil
            }
            if !names.isEmpty { found[topic.slug] = names }
        }
        return found
    }

    // MARK: - The marker

    @Test("The marker becomes a picture, and an ordinary comment still disappears")
    func markerParses() {
        let document = MarkdownDocument("""
        ## A topic

        An opening sentence.

        <!-- illustration: fingerprint -->

        <!-- an editorial note, which is not content -->

        The rest of it.
        """)

        #expect(document.blocks == [
            .heading(level: 2, text: "A topic"),
            .paragraph("An opening sentence."),
            .illustration("fingerprint"),
            .paragraph("The rest of it."),
        ])
    }

    @Test("A marker that nearly matches is a comment, not a picture")
    func markerIsStrict() {
        // Each of these would otherwise vanish silently, taking a picture with it.
        for line in [
            "<!--illustration: fingerprint -->",
            "<!-- illustrations: fingerprint -->",
            "<!-- illustration: -->",
            "<!-- illustration fingerprint -->",
        ] {
            let document = MarkdownDocument("## T\n\nA sentence.\n\n\(line)\n")
            #expect(
                !document.blocks.contains { if case .illustration = $0 { return true }; return false },
                "\(line) should not be read as an illustration"
            )
        }
    }

    @Test("A picture adds nothing to what search reads")
    func illustrationsAreNotSearchable() throws {
        let guide = try UserGuide("""
        <!-- topic: only -->
        ## A topic

        Prose about the thing.

        <!-- illustration: keychain -->
        """)
        let topic = try #require(guide.topic(slug: "only"))
        // Otherwise typing "keychain" would match a topic because of a marker nobody can read.
        #expect(!topic.searchText.contains("keychain"))
        #expect(topic.searchText.contains("Prose about the thing."))
    }

    // MARK: - The guides that ship

    @Test("Every marker in every language names a picture that exists", arguments: languages)
    func everyNameResolves(language: String) throws {
        let found = try illustrations(language)
        #expect(!found.isEmpty, "\(language) has no illustrations at all")
        for (slug, names) in found {
            for name in names {
                #expect(
                    TutorialPage.Illustration(rawValue: name) != nil,
                    "\(language)/\(slug) asks for “\(name)”, which is not a drawing"
                )
            }
        }
    }

    @Test("The three languages carry the same pictures in the same topics")
    func languagesAgree() throws {
        let english = try illustrations("en")
        #expect(english.count >= 8, "the English guide illustrates only \(english.count) topics")
        for language in Self.languages.dropFirst() {
            // A translation is the same guide. Losing the pictures in one of them is the
            // failure this catches, and it is the likely one: prose gets rewritten, markers
            // get dropped in the rewrite.
            #expect(try illustrations(language) == english, "\(language) illustrates different topics than English")
        }
    }

    @Test("A picture comes after the opening sentence, not before it")
    func pictureFollowsTheLead() throws {
        for language in Self.languages {
            for topic in try guide(language).topics {
                guard let index = topic.document.blocks.firstIndex(where: {
                    if case .illustration = $0 { return true }
                    return false
                }) else { continue }
                let before = topic.document.blocks[..<index]
                #expect(
                    before.contains { if case .paragraph = $0 { return true }; return false },
                    "\(language)/\(topic.slug) opens with a picture — the reader needs the sentence first"
                )
                // …and the summary in the topic list is still that sentence rather than empty.
                #expect(!topic.summary.isEmpty, "\(language)/\(topic.slug) has no summary")
            }
        }
    }

    @Test("Every drawing the app can make is either on the tour or in the guide")
    func nothingIsDrawnForNobody() throws {
        let onTheTour = Set(TutorialPage.all.map(\.illustration))
        let inTheGuide = Set(try illustrations("en").values.flatMap { $0 }
            .compactMap(TutorialPage.Illustration.init(rawValue:)))
        for kind in TutorialPage.Illustration.allCases {
            #expect(
                onTheTour.contains(kind) || inTheGuide.contains(kind),
                "\(kind.rawValue) is drawn and never shown"
            )
        }
    }

    @Test("The legal texts carry no markers")
    func legalDocumentsHaveNoPictures() throws {
        for document in [LegalDocument.terms, .privacy, .notice, .licences] {
            let parsed = MarkdownDocument(try document.markdown())
            #expect(
                !parsed.blocks.contains { if case .illustration = $0 { return true }; return false },
                "\(document.rawValue) should be words only"
            )
        }
    }
}
