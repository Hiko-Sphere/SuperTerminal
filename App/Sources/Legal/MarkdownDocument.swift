import Foundation

/// The block structure of a Markdown document, enough for the legal texts: headings,
/// paragraphs, bullet and numbered lists, tables and rules. Inline styling is left to
/// `AttributedString(markdown:)` at render time.
///
/// Written rather than imported because the documents are ours: a parser for exactly
/// what they contain is smaller than any general one and has nothing that can render
/// arbitrary HTML.
struct MarkdownDocument: Equatable {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullets([String])
        case numbered([String])
        case table(header: [String], rows: [[String]])
        case rule
        /// A drawn picture, named by an ``TutorialPage/Illustration`` raw value (D-080).
        ///
        /// A block rather than an image URL because there is no image: the pictures are
        /// drawn from the same design tokens as the interface they describe, so they cannot
        /// go stale the way a screenshot of the app inside the app does.
        case illustration(String)
    }

    let blocks: [Block]

    init(_ source: String) {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var table: [[String]] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
            if !table.isEmpty {
                let header = table[0]
                // The second row is the `| --- |` separator when present.
                let body = table.dropFirst().filter { row in !row.allSatisfy { $0.allSatisfy { $0 == "-" || $0 == ":" } } }
                blocks.append(.table(header: header, rows: Array(body)))
                table = []
            }
        }

        for rawLine in Self.stripComments(source).components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let name = Self.illustrationName(line) {
                flush()
                blocks.append(.illustration(name))
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                blocks.append(.heading(level: level, text: line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line == "---" || line == "***" {
                flush(); blocks.append(.rule)
            } else if line.hasPrefix("|") {
                if !paragraph.isEmpty || !bullets.isEmpty || !numbered.isEmpty { flush() }
                let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                    .dropFirst().dropLast()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                table.append(cells)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !paragraph.isEmpty || !numbered.isEmpty || !table.isEmpty { flush() }
                bullets.append(String(line.dropFirst(2)))
            } else if let item = Self.numberedItem(line) {
                if !paragraph.isEmpty || !bullets.isEmpty || !table.isEmpty { flush() }
                numbered.append(item)
            } else if !bullets.isEmpty {
                // A wrapped continuation of the previous bullet.
                bullets[bullets.count - 1] += " " + line
            } else if !numbered.isEmpty {
                numbered[numbered.count - 1] += " " + line
            } else {
                if !table.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        self.blocks = blocks
    }

    /// Drops HTML comments, which the sources use for editorial notes — except the one
    /// form that is not a note.
    ///
    /// `<!-- illustration: fingerprint -->` is content, and it is written as a comment on
    /// purpose: the guide files are also read as plain Markdown, on GitHub and in any editor,
    /// and a marker that showed up there as literal text would be a wart in the prose. A
    /// comment is invisible everywhere except to the one reader that is looking for it.
    static func stripComments(_ source: String) -> String {
        var result = ""
        var rest = Substring(source)
        while let start = rest.range(of: "<!--") {
            guard let end = rest.range(of: "-->", range: start.upperBound ..< rest.endIndex) else { break }
            result += rest[rest.startIndex ..< start.lowerBound]
            let comment = rest[start.lowerBound ..< end.upperBound]
            if illustrationName(String(comment)) != nil { result += comment }
            rest = rest[end.upperBound...]
        }
        result += rest
        return result
    }

    /// `<!-- illustration: fingerprint -->` and nothing else. Strict for the same reason the
    /// topic marker is: a marker that nearly matches would vanish silently, and a picture that
    /// is simply absent is not something anybody notices is missing.
    static func illustrationName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!-- illustration:"), trimmed.hasSuffix("-->") else { return nil }
        let name = trimmed
            .dropFirst("<!-- illustration:".count)
            .dropLast("-->".count)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func numberedItem(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: "."), dot != line.startIndex,
              line[..<dot].allSatisfy(\.isNumber),
              line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " "
        else { return nil }
        return String(line[line.index(dot, offsetBy: 2)...])
    }
}
