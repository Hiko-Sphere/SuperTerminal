import Foundation

/// A position in the terminal's full content, counting scrollback.
///
/// Absolute rather than screen-relative on purpose: a selection made three screens back
/// must stay on the text it was made on when new output arrives and everything scrolls.
/// Screen-relative coordinates would silently slide onto different characters.
public struct TerminalPosition: Sendable, Equatable, Hashable, Comparable {
    /// Index into `scrollback + lines`.
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static func < (lhs: TerminalPosition, rhs: TerminalPosition) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }
}

/// A range of selected text.
public struct TerminalRange: Sendable, Equatable {
    public var start: TerminalPosition
    public var end: TerminalPosition
    /// Block selection takes the same column range from every row, which is what makes
    /// copying one column out of `ps` or `df` output possible at all.
    public var isBlock: Bool

    public init(start: TerminalPosition, end: TerminalPosition, isBlock: Bool = false) {
        self.start = start
        self.end = end
        self.isBlock = isBlock
    }

    /// Ordered so `start` precedes `end` in reading order.
    public var normalised: TerminalRange {
        guard start > end else { return self }
        return TerminalRange(start: end, end: start, isBlock: isBlock)
    }

    public func contains(_ position: TerminalPosition) -> Bool {
        let range = normalised
        if isBlock {
            let lowColumn = min(range.start.column, range.end.column)
            let highColumn = max(range.start.column, range.end.column)
            return position.row >= range.start.row
                && position.row <= range.end.row
                && position.column >= lowColumn
                && position.column <= highColumn
        }
        if position.row < range.start.row || position.row > range.end.row { return false }
        if range.start.row == range.end.row {
            return position.column >= range.start.column && position.column <= range.end.column
        }
        if position.row == range.start.row { return position.column >= range.start.column }
        if position.row == range.end.row { return position.column <= range.end.column }
        return true
    }
}

/// A search hit.
public struct TerminalSearchMatch: Sendable, Equatable {
    public let range: TerminalRange
    /// The line the match sits on, for showing context in a results list.
    public let lineText: String
}

public extension TerminalScreen {
    /// Every line, history first. The coordinate space selections and searches use.
    var allLines: [TerminalLine] { scrollback + lines }

    /// Total rows including history.
    var totalRows: Int { scrollback.count + lines.count }

    /// Extracts the text covered by `range`.
    ///
    /// Trailing padding on each row is dropped, and a row that was a soft wrap is joined
    /// to the next without a newline — so copying a wrapped command gives back the
    /// command, not the command with a newline injected wherever the terminal happened to
    /// run out of width. Pasting that newline into a shell would run half a command.
    func text(in range: TerminalRange) -> String {
        let all = allLines
        let normalised = range.normalised
        guard !all.isEmpty else { return "" }

        let firstRow = max(0, normalised.start.row)
        let lastRow = min(all.count - 1, normalised.end.row)
        guard firstRow <= lastRow else { return "" }

        var pieces: [String] = []
        for row in firstRow ... lastRow {
            let line = all[row]
            let columns = columnRange(for: normalised, row: row, lineWidth: line.width)
            guard let columns else { continue }

            var text = ""
            var column = columns.lowerBound
            while column <= columns.upperBound, column < line.width {
                let cell = line[column]
                if !cell.isWideContinuation {
                    text.append(cell.character ?? " ")
                }
                column += 1
            }
            // Only trim padding at the true end of a row; a mid-row selection's spaces
            // were deliberately selected.
            if columns.upperBound >= line.width - 1 {
                while text.hasSuffix(" ") { text.removeLast() }
            }

            let joinsToNext = line.isWrapped && row < lastRow && !normalised.isBlock
            pieces.append(text + (joinsToNext ? "" : "\n"))
        }

        var result = pieces.joined()
        if result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    private func columnRange(
        for range: TerminalRange,
        row: Int,
        lineWidth: Int
    ) -> ClosedRange<Int>? {
        guard lineWidth > 0 else { return nil }
        if range.isBlock {
            let low = max(0, min(range.start.column, range.end.column))
            let high = min(lineWidth - 1, max(range.start.column, range.end.column))
            return low <= high ? low ... high : nil
        }
        let start = row == range.start.row ? max(0, range.start.column) : 0
        let end = row == range.end.row ? min(lineWidth - 1, range.end.column) : lineWidth - 1
        return start <= end ? start ... end : nil
    }

    /// The whole of one line, following soft wraps in both directions.
    ///
    /// This is what a double-tap should select: the logical line a person sees, not the
    /// row the terminal happened to break it into.
    func logicalLineRange(containing row: Int) -> TerminalRange? {
        let all = allLines
        guard all.indices.contains(row) else { return nil }
        var first = row
        while first > 0, all[first - 1].isWrapped { first -= 1 }
        var last = row
        while last < all.count - 1, all[last].isWrapped { last += 1 }
        return TerminalRange(
            start: TerminalPosition(row: first, column: 0),
            end: TerminalPosition(row: last, column: max(0, all[last].width - 1))
        )
    }

    /// Searches the whole buffer, history included.
    ///
    /// Matching runs against each *logical* line rather than each row, so a term that was
    /// split across a wrap is still found — which is exactly the case where a person most
    /// needs search, because they cannot see the break.
    func search(
        for query: String,
        caseSensitive: Bool = false,
        limit: Int = 500
    ) -> [TerminalSearchMatch] {
        guard !query.isEmpty else { return [] }
        let all = allLines
        guard !all.isEmpty else { return [] }

        var matches: [TerminalSearchMatch] = []
        var row = 0
        while row < all.count, matches.count < limit {
            // Build the logical line and remember which row each character came from.
            var text = ""
            var origins: [(row: Int, column: Int)] = []
            var cursorRow = row
            while cursorRow < all.count {
                let line = all[cursorRow]
                for column in 0 ..< line.width {
                    let cell = line[column]
                    if cell.isWideContinuation { continue }
                    text.append(cell.character ?? " ")
                    origins.append((cursorRow, column))
                }
                if line.isWrapped, cursorRow < all.count - 1 {
                    cursorRow += 1
                } else {
                    break
                }
            }

            let haystack = caseSensitive ? text : text.lowercased()
            let needle = caseSensitive ? query : query.lowercased()
            var searchStart = haystack.startIndex
            while matches.count < limit,
                  let found = haystack.range(of: needle, range: searchStart ..< haystack.endIndex)
            {
                let startOffset = haystack.distance(from: haystack.startIndex, to: found.lowerBound)
                let endOffset = haystack.distance(from: haystack.startIndex, to: found.upperBound) - 1
                if origins.indices.contains(startOffset), origins.indices.contains(endOffset) {
                    let start = origins[startOffset]
                    let end = origins[endOffset]
                    matches.append(TerminalSearchMatch(
                        range: TerminalRange(
                            start: TerminalPosition(row: start.row, column: start.column),
                            end: TerminalPosition(row: end.row, column: end.column)
                        ),
                        lineText: text.trimmingCharacters(in: .whitespaces)
                    ))
                }
                searchStart = haystack.index(after: found.lowerBound)
            }

            row = cursorRow + 1
        }
        return matches
    }
}
