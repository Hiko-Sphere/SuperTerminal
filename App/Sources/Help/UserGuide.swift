import Foundation

/// The user guide, parsed from the Markdown shipped in the bundle.
///
/// The guide is one file per language rather than a wall of localized string literals:
/// it is prose, it is edited as prose, and a translator needs to see a paragraph in its
/// context to translate it. What the app needs from it is structure — a list of topics
/// that can be searched and opened — so the file marks each topic with a stable slug and
/// this type turns the file into topics.
///
/// The slug is what makes the three languages the same guide: titles differ, ordering is
/// the file's, but `split-panes` is `split-panes` everywhere, so a symbol, a test or a
/// deep link can name a topic without naming a language.
struct UserGuide: Equatable {
    struct Topic: Identifiable, Equatable {
        let slug: String
        let title: String
        /// The first paragraph, shown under the title in the list. A topic that opens
        /// with a table or a list has none, which the list handles.
        let summary: String
        let document: MarkdownDocument
        /// Title and body, folded once at parse time so searching does not re-walk the
        /// blocks on every keystroke.
        let searchText: String

        var id: String { slug }
        var symbol: String { UserGuide.symbol(for: slug) }
    }

    let topics: [Topic]

    /// Parses the guide. Content before the first topic marker is a defect rather than a
    /// preamble — it would be unreachable in the app — so it is reported, not ignored.
    init(_ source: String) throws {
        var topics: [Topic] = []
        var slug: String?
        var lines: [String] = []

        func finish() throws {
            guard let current = slug else { return }
            let body = lines.joined(separator: "\n")
            let document = MarkdownDocument(body)
            guard case let .heading(_, title)? = document.blocks.first else {
                throw UserGuideError.topicWithoutHeading(current)
            }
            let summary = document.blocks.compactMap { block -> String? in
                if case let .paragraph(text) = block { return text }
                return nil
            }.first ?? ""
            topics.append(
                Topic(
                    slug: current,
                    title: title,
                    summary: summary,
                    document: document,
                    searchText: ([title] + Self.plainText(document)).joined(separator: "\n")
                )
            )
            lines = []
        }

        for line in source.components(separatedBy: "\n") {
            if let marker = Self.topicMarker(line) {
                try finish()
                slug = marker
            } else if slug == nil {
                guard line.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw UserGuideError.contentBeforeFirstTopic
                }
            } else {
                lines.append(line)
            }
        }
        try finish()

        guard !topics.isEmpty else { throw UserGuideError.empty }
        let slugs = topics.map(\.slug)
        if let duplicate = slugs.first(where: { slug in slugs.filter { $0 == slug }.count > 1 }) {
            throw UserGuideError.duplicateTopic(duplicate)
        }
        self.topics = topics
    }

    /// `<!-- topic: split-panes -->` and nothing else. Deliberately strict: a marker that
    /// nearly matches would silently fold two topics into one.
    private static func topicMarker(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!-- topic:"), trimmed.hasSuffix("-->") else { return nil }
        let slug = trimmed
            .dropFirst("<!-- topic:".count)
            .dropLast("-->".count)
            .trimmingCharacters(in: .whitespaces)
        return slug.isEmpty ? nil : slug
    }

    private static func plainText(_ document: MarkdownDocument) -> [String] {
        document.blocks.flatMap { block -> [String] in
            switch block {
            case let .heading(_, text): [text]
            case let .paragraph(text): [text]
            case let .bullets(items): items
            case let .numbered(items): items
            case let .table(header, rows): header + rows.flatMap { $0 }
            case .rule: []
            }
        }
    }

    /// Topics whose title or body contains the query, in the guide's own order. Matching
    /// is `localizedStandardContains`, which is what a person means by "search": case and
    /// diacritics are ignored, and it does the right thing for Chinese, where there are
    /// no word boundaries to tokenise on.
    func topics(matching query: String) -> [Topic] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return topics }
        return topics.filter { $0.searchText.localizedStandardContains(trimmed) }
    }

    func topic(slug: String) -> Topic? { topics.first { $0.slug == slug } }

    /// The language folder the guide is read from, reduced to the three it exists in —
    /// the app's own localisation rather than the system locale, so the guide matches the
    /// UI around it.
    static var documentLanguage: String { LegalDocument.documentLanguage }

    static func bundled(bundle: Bundle = .main) throws -> UserGuide {
        let name = "guide-\(documentLanguage)"
        guard let url = bundle.url(forResource: name, withExtension: "md") else {
            throw UserGuideError.missing(name)
        }
        return try UserGuide(String(contentsOf: url, encoding: .utf8))
    }

    /// One symbol per topic, chosen once so the list reads as a list rather than as
    /// eighteen variations of a book. A slug with no symbol is a mistake caught by a test
    /// rather than a question mark on screen.
    static let symbols: [String: String] = [
        "getting-started": "bolt.horizontal",
        "signing-in": "person.badge.key",
        "keys": "key",
        "agent-forwarding": "arrow.up.forward.app",
        "host-keys": "checkmark.seal",
        "cloudflare": "cloud",
        "jump-hosts": "arrow.triangle.branch",
        "terminal": "terminal",
        "panes": "rectangle.split.2x1",
        "tmux": "square.split.bottomrightquarter",
        "sessions": "square.stack",
        "files": "folder",
        "forwarding": "arrow.left.arrow.right",
        "screens": "display",
        "snippets": "command",
        "links": "link",
        "shortcuts": "keyboard",
        "assistant": "sparkles",
        "privacy": "lock.shield",
        "troubleshooting": "stethoscope",
    ]

    static func symbol(for slug: String) -> String { symbols[slug] ?? "book" }
}

enum UserGuideError: Error, LocalizedError, Equatable {
    case missing(String)
    case empty
    case contentBeforeFirstTopic
    case topicWithoutHeading(String)
    case duplicateTopic(String)

    var errorDescription: String? {
        switch self {
        case let .missing(name):
            String(localized: "The guide \(name) is not included in this build.")
        case .empty, .contentBeforeFirstTopic, .topicWithoutHeading, .duplicateTopic:
            String(localized: "The guide in this build is damaged.")
        }
    }
}
