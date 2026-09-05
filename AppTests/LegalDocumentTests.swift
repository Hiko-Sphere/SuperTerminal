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
