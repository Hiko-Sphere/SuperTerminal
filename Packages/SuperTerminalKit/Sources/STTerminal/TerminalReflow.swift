import Foundation

extension TerminalScreen {
    /// Re-wraps content when the number of columns changes.
    ///
    /// ## Why this is worth the complexity
    ///
    /// On a phone, the column count changes constantly: rotating the device, showing and
    /// hiding the keyboard, resizing a Stage Manager window. Without reflow, a paragraph
    /// wrapped at 80 columns keeps its hard break when the terminal becomes 100 wide, so
    /// the history turns into a ragged column with a gap down the right-hand side — and
    /// narrowing simply truncates, losing text outright.
    ///
    /// The `isWrapped` flag is what makes this possible: it distinguishes a line that ran
    /// out of room from one the program deliberately ended, and only the former may be
    /// rejoined. Without that distinction, reflow would glue together lines a program
    /// meant to keep apart — which is worse than not reflowing at all.
    mutating func reflow(toColumns newColumns: Int) {
        let target = max(1, newColumns)
        guard target != columns else { return }

        // Absolute index of the cursor within the joined content, so it can be put back
        // where it belongs rather than approximated.
        let cursorAbsoluteRow = scrollback.count + cursor.row
        var cursorCellOffset: Int?

        var allLines = scrollback + lines
        // Blank rows below the last content are screen padding, not history. Treating
        // them as content would push real text off the top every time the terminal was
        // narrowed — the paragraph would reflow correctly and then immediately scroll
        // out of sight, which looks exactly like data loss.
        var lastMeaningful = cursorAbsoluteRow
        for (index, line) in allLines.enumerated() where line.cells.contains(where: { !$0.isBlank }) {
            lastMeaningful = max(lastMeaningful, index)
        }
        if lastMeaningful + 1 < allLines.count {
            allLines.removeSubrange((lastMeaningful + 1)...)
        }

        var logical: [(cells: [TerminalCell], cursorOffset: Int?)] = []
        var current: [TerminalCell] = []
        var currentCursorOffset: Int?

        for (index, line) in allLines.enumerated() {
            var cells = line.cells
            // Trailing blanks are padding, not content: keeping them would re-wrap a
            // short line into a full-width one made mostly of spaces.
            while let last = cells.last, last.isBlank, last.attributes.background == .default {
                cells.removeLast()
            }
            if index == cursorAbsoluteRow {
                currentCursorOffset = current.count + cursor.column
            }
            current.append(contentsOf: cells)

            if line.isWrapped, index < allLines.count - 1 {
                continue
            }
            logical.append((current, currentCursorOffset))
            current = []
            currentCursorOffset = nil
        }
        if !current.isEmpty || logical.isEmpty {
            logical.append((current, currentCursorOffset))
        }

        var rewrapped: [TerminalLine] = []
        var cursorRowInResult: Int?
        var cursorColumnInResult = 0

        for entry in logical {
            let chunks = Self.wrap(entry.cells, toWidth: target)
            if let offset = entry.cursorOffset {
                var remaining = offset
                var placed = false
                for (chunkIndex, chunk) in chunks.enumerated() {
                    if remaining < chunk.count || chunkIndex == chunks.count - 1 {
                        cursorRowInResult = rewrapped.count + chunkIndex
                        cursorColumnInResult = min(remaining, max(0, target - 1))
                        placed = true
                        break
                    }
                    remaining -= chunk.count
                }
                if !placed {
                    cursorRowInResult = rewrapped.count + max(0, chunks.count - 1)
                    cursorColumnInResult = 0
                }
            }
            for (chunkIndex, chunk) in chunks.enumerated() {
                var padded = chunk
                if padded.count < target {
                    padded.append(contentsOf: Array(repeating: .blank, count: target - padded.count))
                }
                rewrapped.append(TerminalLine(cells: padded, isWrapped: chunkIndex < chunks.count - 1))
            }
        }

        cursorCellOffset = cursorRowInResult

        // The screen keeps the last `rows` lines; everything above becomes history.
        if rewrapped.count < rows {
            rewrapped.append(contentsOf: (rewrapped.count ..< rows).map { _ in TerminalLine(width: target) })
        }
        let screenStart = max(0, rewrapped.count - rows)
        var newScrollback = Array(rewrapped[0 ..< screenStart])
        if newScrollback.count > scrollbackLimit {
            newScrollback.removeFirst(newScrollback.count - scrollbackLimit)
        }

        applyReflow(
            scrollback: newScrollback,
            lines: Array(rewrapped[screenStart...]),
            columns: target,
            cursorRow: (cursorCellOffset ?? (rewrapped.count - 1)) - screenStart,
            cursorColumn: cursorColumnInResult
        )
    }

    /// Splits a run of cells into chunks that fit `width`, never breaking a double-width
    /// character across the margin.
    static func wrap(_ cells: [TerminalCell], toWidth width: Int) -> [[TerminalCell]] {
        guard !cells.isEmpty else { return [[]] }
        var chunks: [[TerminalCell]] = []
        var current: [TerminalCell] = []

        var index = 0
        while index < cells.count {
            let cell = cells[index]
            // A wide character and its continuation move together, so a resize can never
            // orphan half of one.
            let isWidePair = index + 1 < cells.count && cells[index + 1].isWideContinuation
            let needed = isWidePair ? 2 : 1

            if current.count + needed > width, !current.isEmpty {
                chunks.append(current)
                current = []
            }
            current.append(cell)
            if isWidePair {
                current.append(cells[index + 1])
                index += 2
            } else {
                index += 1
            }
        }
        chunks.append(current)
        return chunks
    }
}
