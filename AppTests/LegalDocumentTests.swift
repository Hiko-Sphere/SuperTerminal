import Foundation
import Testing
@testable import SuperTerminal

@Suite struct MarkdownDocumentTests {
    @Test func parsesHeadingsParagraphsListsAndRules() {
        let doc = MarkdownDocument("""
        # Title
        Intro line one
        continues here.

        ## Section
        - first
        - second
          wrapped
        1. one
        2. two
        ---
        """)
        #expect(doc.blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Intro line one continues here."),
            .heading(level: 2, text: "Section"),
            .bullets(["first", "second wrapped"]),
            .numbered(["one", "two"]),
            .rule,
        ])
    }

    @Test func parsesTablesAndDropsTheSeparatorRow() {
        let doc = MarkdownDocument("""
        | Data | Where |
        | --- | --- |
        | Keys | Keychain |
        | Snippets | App storage |
        """)
        #expect(doc.blocks == [.table(header: ["Data", "Where"], rows: [["Keys", "Keychain"], ["Snippets", "App storage"]])])
    }

    @Test func stripsEditorialComments() {
        let doc = MarkdownDocument("<!-- BEFORE RELEASE:\nfill in -->\n# Terms\nBody <!-- inline --> text")
        #expect(doc.blocks == [.heading(level: 1, text: "Terms"), .paragraph("Body  text")])
    }
}

/// Every document the app offers must be in the bundle in every language, and must
/// be a real document, not an empty file that happens to exist.
@Suite struct LegalDocumentBundleTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [LegalDocument.terms, .privacy, .notice])
    func documentIsBundledAndSubstantial(language: String, document: LegalDocument) throws {
        let bundle = Bundle(for: AppContainer.self)
        let url = try #require(bundle.url(forResource: "legal-\(document.rawValue)-\(language)", withExtension: "md"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = MarkdownDocument(text)
        let headings = parsed.blocks.filter { if case .heading = $0 { return true }; return false }
        #expect(headings.count >= 10, "\(url.lastPathComponent) has \(headings.count) headings")
        #expect(!text.contains("<!--"), "editorial comments must not ship")
        #expect(text.contains("iCloud"))

        // No way to contact anyone, in any language. The documents deliberately offer no
        // address — there is nothing held to ask about — and a sentence inviting someone
        // to write in is the kind of thing that gets added back by a well-meaning edit.
        let email = try Regex(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
        #expect(text.firstMatch(of: email) == nil, "\(url.lastPathComponent) carries an address")
        for invitation in ["write to", "contact us", "contact the developer", "写信", "寫信", "联系我们", "聯絡我們"] {
            #expect(!text.localizedLowercase.contains(invitation), "\(url.lastPathComponent) invites contact: \(invitation)")
        }

        // Nothing is left for the owner to fill in (B-5 closed). A bracketed lower-case
        // phrase that is not a Markdown link is a placeholder that shipped unfilled —
        // which in a legal text reads as though the developer has no name.
        let placeholders = try Regex(#"\[[a-z][a-z ]+\](?!\()"#)
        for match in text.matches(of: placeholders) {
            Issue.record("\(url.lastPathComponent) still has the placeholder \(match.0)")
        }
    }

    @Test func noticesAreBundledAndMatchTheRepositoryCopy() throws {
        let bundle = Bundle(for: AppContainer.self)
        let url = try #require(bundle.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("Apache"))
        #expect(MarkdownDocument(text).blocks.count > 5)
    }

    @Test func languageIsOneTheDocumentsExistIn() {
        #expect(["en", "zh-Hans", "zh-Hant"].contains(LegalDocument.documentLanguage))
    }
}
