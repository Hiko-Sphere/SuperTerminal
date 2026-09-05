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
            if line.hasPrefix("#") {
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

    /// Drops HTML comments, which the sources use for editorial notes.
    static func stripComments(_ source: String) -> String {
        var result = source
        while let start = result.range(of: "<!--"), let end = result.range(of: "-->", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }

    private static func numberedItem(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: "."), dot != line.startIndex,
              line[..<dot].allSatisfy(\.isNumber),
              line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " "
        else { return nil }
        return String(line[line.index(dot, offsetBy: 2)...])
    }
}
