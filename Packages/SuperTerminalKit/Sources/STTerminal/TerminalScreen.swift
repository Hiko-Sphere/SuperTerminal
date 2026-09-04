import Foundation

/// A colour as a terminal expresses it.
///
/// The three cases exist because they behave differently, not merely because SGR spells
/// them differently: `default` follows the user's theme, `indexed` follows the palette
/// (so a theme change restyles existing content), and `rgb` is fixed by the remote
/// program and must be honoured exactly.
public enum TerminalColor: Sendable, Equatable, Hashable {
    case `default`
    case indexed(UInt8)
    case rgb(red: UInt8, green: UInt8, blue: UInt8)
}

/// Visual attributes of a cell.
public struct CellAttributes: Sendable, Equatable, Hashable {
    public var foreground: TerminalColor = .default
    public var background: TerminalColor = .default
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var doubleUnderline = false
    public var blink = false
    public var inverse = false
    public var invisible = false
    public var strikethrough = false
    /// Index into the emulator's hyperlink table, set by OSC 8.
    public var hyperlinkID: Int?

    public init() {}

    public static let normal = CellAttributes()
}

/// One character cell.
public struct TerminalCell: Sendable, Equatable {
    /// The grapheme cluster displayed here. `nil` means blank.
    public var character: Character?
    public var attributes: CellAttributes
    /// `true` when this cell is the right-hand half of a double-width character. Its
    /// `character` is `nil`, and writing to it must clear the whole pair — otherwise a
    /// half-overwritten wide character leaves an orphaned continuation cell that shifts
    /// everything after it.
    public var isWideContinuation: Bool

    public init(
        character: Character? = nil,
        attributes: CellAttributes = .normal,
        isWideContinuation: Bool = false
    ) {
        self.character = character
        self.attributes = attributes
        self.isWideContinuation = isWideContinuation
    }

    public static let blank = TerminalCell()

    public var isBlank: Bool { character == nil && !isWideContinuation }
}

/// One line of the screen or scrollback.
public struct TerminalLine: Sendable, Equatable {
    public private(set) var cells: [TerminalCell]
    /// Set when the line filled up and the next character wrapped onto the following
    /// line. Reflow on resize needs this to know which lines were one logical line.
    public var isWrapped: Bool

    public init(width: Int, isWrapped: Bool = false) {
        cells = Array(repeating: .blank, count: max(0, width))
        self.isWrapped = isWrapped
    }

    public init(cells: [TerminalCell], isWrapped: Bool = false) {
        self.cells = cells
        self.isWrapped = isWrapped
    }

    public var width: Int { cells.count }

    public subscript(index: Int) -> TerminalCell {
        get { cells[index] }
        set { cells[index] = newValue }
    }

    public mutating func resize(to width: Int) {
        if width < cells.count {
            cells.removeLast(cells.count - width)
        } else if width > cells.count {
            cells.append(contentsOf: Array(repeating: .blank, count: width - cells.count))
        }
    }

    public mutating func clear(from start: Int, through end: Int, attributes: CellAttributes) {
        guard start <= end, start < cells.count else { return }
        var blank = TerminalCell.blank
        // Erasing paints the *current* background, which is how programs draw coloured
        // regions with `ED`/`EL` rather than by writing spaces.
        blank.attributes.background = attributes.background
        for index in max(0, start) ... min(end, cells.count - 1) {
            cells[index] = blank
        }
    }

    /// The line's text, with trailing blanks trimmed. Used for selection and search.
    public var text: String {
        var result = ""
        for cell in cells {
            if cell.isWideContinuation { continue }
            result.append(cell.character ?? " ")
        }
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }
}

/// Cursor position and appearance.
public struct TerminalCursor: Sendable, Equatable {
    public var row: Int = 0
    public var column: Int = 0
    public var isVisible = true
    public var style: Style = .block
    public var blinks = true

    public enum Style: Sendable, Equatable {
        case block
        case underline
        case bar
    }

    public init() {}
}

/// The grid, its scrollback, and the state that makes editing it correct.
///
/// Kept deliberately free of escape-sequence knowledge: this type knows how to move a
/// cursor, scroll a region and erase, and ``TerminalEmulator`` decides when to. Splitting
/// them is what allows the screen's edge cases — wide characters at the right margin,
/// scroll regions, the alternate buffer — to be tested without going through a byte
/// stream first.
public struct TerminalScreen: Sendable {
    public private(set) var columns: Int
    public private(set) var rows: Int
    public private(set) var lines: [TerminalLine]
    /// Lines that have scrolled off the top. Bounded; the oldest are discarded.
    public private(set) var scrollback: [TerminalLine]
    public var cursor = TerminalCursor()
    public var attributes: CellAttributes = .normal
    public var scrollbackLimit: Int

    /// Top and bottom rows of the scrolling region, inclusive, in screen coordinates.
    public private(set) var scrollTop: Int
    public private(set) var scrollBottom: Int

    /// Set once the cursor has been parked past the last column. The next printable
    /// character wraps. Deferring the wrap like this — rather than moving the cursor
    /// immediately — is what makes writing exactly `columns` characters not scroll the
    /// screen, which is the behaviour every full-screen program depends on.
    public var pendingWrap = false

    public init(columns: Int, rows: Int, scrollbackLimit: Int = 10000) {
        let width = max(1, columns)
        let height = max(1, rows)
        self.columns = width
        self.rows = height
        self.scrollbackLimit = max(0, scrollbackLimit)
        lines = (0 ..< height).map { _ in TerminalLine(width: width) }
        scrollback = []
        scrollTop = 0
        scrollBottom = height - 1
    }

    // MARK: - Writing

    /// Writes one grapheme cluster at the cursor, handling wrapping and wide characters.
    public mutating func write(_ character: Character) {
        let width = CharacterWidth.of(character)
        // Fast path for the common case: a single-width character landing in a cell that
        // holds nothing wide, with no wrap pending. Skips the wide-character bookkeeping
        // entirely, which is most of the cost of writing ordinary text.
        if width == 1, !pendingWrap, cursor.column + 1 < columns {
            let existing = lines[cursor.row][cursor.column]
            if !existing.isWideContinuation, existing.character == nil || existing.character!.isASCII {
                lines[cursor.row][cursor.column] = TerminalCell(character: character, attributes: attributes)
                cursor.column += 1
                return
            }
        }

        if pendingWrap {
            lines[cursor.row].isWrapped = true
            carriageReturn()
            lineFeed()
            pendingWrap = false
        }

        // A double-width character that will not fit in the last column moves to the
        // next line whole. Splitting it across the margin would corrupt every column
        // after it.
        if width == 2, cursor.column == columns - 1 {
            lines[cursor.row][cursor.column] = TerminalCell(character: nil, attributes: attributes)
            lines[cursor.row].isWrapped = true
            carriageReturn()
            lineFeed()
        }

        clearWideCharacter(at: cursor.column)
        lines[cursor.row][cursor.column] = TerminalCell(character: character, attributes: attributes)

        if width == 2, cursor.column + 1 < columns {
            clearWideCharacter(at: cursor.column + 1)
            lines[cursor.row][cursor.column + 1] = TerminalCell(
                character: nil,
                attributes: attributes,
                isWideContinuation: true
            )
        }

        let advance = max(1, width)
        if cursor.column + advance >= columns {
            cursor.column = columns - 1
            pendingWrap = true
        } else {
            cursor.column += advance
        }
    }

    /// Overwriting either half of a wide character must clear both, or the surviving
    /// half renders as a stray glyph or a phantom blank.
    private mutating func clearWideCharacter(at column: Int) {
        guard column >= 0, column < columns else { return }
        let cell = lines[cursor.row][column]
        if cell.isWideContinuation, column > 0 {
            lines[cursor.row][column - 1] = TerminalCell(attributes: attributes)
        } else if cell.character != nil,
                  CharacterWidth.of(cell.character!) == 2,
                  column + 1 < columns,
                  lines[cursor.row][column + 1].isWideContinuation {
            lines[cursor.row][column + 1] = TerminalCell(attributes: attributes)
        }
    }

    // MARK: - Cursor movement

    public mutating func carriageReturn() {
        cursor.column = 0
        pendingWrap = false
    }

    public mutating func lineFeed() {
        pendingWrap = false
        if cursor.row == scrollBottom {
            scrollUp(1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
    }

    public mutating func reverseLineFeed() {
        pendingWrap = false
        if cursor.row == scrollTop {
            scrollDown(1)
        } else if cursor.row > 0 {
            cursor.row -= 1
        }
    }

    public mutating func moveCursor(row: Int, column: Int) {
        cursor.row = min(max(0, row), rows - 1)
        cursor.column = min(max(0, column), columns - 1)
        pendingWrap = false
    }

    public mutating func moveCursorRelative(rows deltaRows: Int, columns deltaColumns: Int) {
        moveCursor(row: cursor.row + deltaRows, column: cursor.column + deltaColumns)
    }

    // MARK: - Scrolling

    public mutating func setScrollRegion(top: Int, bottom: Int) {
        let newTop = min(max(0, top), rows - 1)
        let newBottom = min(max(newTop, bottom), rows - 1)
        guard newBottom > newTop else { return }
        scrollTop = newTop
        scrollBottom = newBottom
    }

    public mutating func resetScrollRegion() {
        scrollTop = 0
        scrollBottom = rows - 1
    }

    public mutating func scrollUp(_ count: Int) {
        guard count > 0 else { return }
        let regionHeight = scrollBottom - scrollTop + 1
        let amount = min(count, regionHeight)
        // Only content scrolling off the *top of the screen* is history. Lines leaving a
        // smaller scroll region belong to a program managing its own layout, and keeping
        // them would fill the user's scrollback with `tmux` status-bar redraws.
        if scrollTop == 0, scrollbackLimit > 0 {
            for index in 0 ..< amount {
                scrollback.append(lines[scrollTop + index])
            }
            if scrollback.count > scrollbackLimit {
                scrollback.removeFirst(scrollback.count - scrollbackLimit)
            }
        }
        lines.removeSubrange(scrollTop ..< (scrollTop + amount))
        lines.insert(
            contentsOf: (0 ..< amount).map { _ in TerminalLine(width: columns) },
            at: scrollTop + regionHeight - amount
        )
    }

    public mutating func scrollDown(_ count: Int) {
        guard count > 0 else { return }
        let regionHeight = scrollBottom - scrollTop + 1
        let amount = min(count, regionHeight)
        lines.removeSubrange((scrollBottom - amount + 1) ... scrollBottom)
        lines.insert(
            contentsOf: (0 ..< amount).map { _ in TerminalLine(width: columns) },
            at: scrollTop
        )
    }

    // MARK: - Erasing

    public mutating func eraseInLine(mode: Int) {
        switch mode {
        case 0: lines[cursor.row].clear(from: cursor.column, through: columns - 1, attributes: attributes)
        case 1: lines[cursor.row].clear(from: 0, through: cursor.column, attributes: attributes)
        case 2: lines[cursor.row].clear(from: 0, through: columns - 1, attributes: attributes)
        default: break
        }
        pendingWrap = false
    }

    public mutating func eraseInDisplay(mode: Int) {
        switch mode {
        case 0:
            lines[cursor.row].clear(from: cursor.column, through: columns - 1, attributes: attributes)
            for row in (cursor.row + 1) ..< rows {
                lines[row].clear(from: 0, through: columns - 1, attributes: attributes)
                lines[row].isWrapped = false
            }
        case 1:
            for row in 0 ..< cursor.row {
                lines[row].clear(from: 0, through: columns - 1, attributes: attributes)
                lines[row].isWrapped = false
            }
            lines[cursor.row].clear(from: 0, through: cursor.column, attributes: attributes)
        case 2, 3:
            for row in 0 ..< rows {
                lines[row].clear(from: 0, through: columns - 1, attributes: attributes)
                lines[row].isWrapped = false
            }
            if mode == 3 { scrollback.removeAll() }
        default:
            break
        }
        pendingWrap = false
    }

    public mutating func insertLines(_ count: Int) {
        guard cursor.row >= scrollTop, cursor.row <= scrollBottom, count > 0 else { return }
        let amount = min(count, scrollBottom - cursor.row + 1)
        lines.removeSubrange((scrollBottom - amount + 1) ... scrollBottom)
        lines.insert(contentsOf: (0 ..< amount).map { _ in TerminalLine(width: columns) }, at: cursor.row)
    }

    public mutating func deleteLines(_ count: Int) {
        guard cursor.row >= scrollTop, cursor.row <= scrollBottom, count > 0 else { return }
        let amount = min(count, scrollBottom - cursor.row + 1)
        lines.removeSubrange(cursor.row ..< (cursor.row + amount))
        lines.insert(
            contentsOf: (0 ..< amount).map { _ in TerminalLine(width: columns) },
            at: scrollBottom - amount + 1
        )
    }

    public mutating func insertCharacters(_ count: Int) {
        guard count > 0 else { return }
        var cells = lines[cursor.row].cells
        let amount = min(count, columns - cursor.column)
        cells.removeLast(amount)
        var blank = TerminalCell.blank
        blank.attributes.background = attributes.background
        cells.insert(contentsOf: Array(repeating: blank, count: amount), at: cursor.column)
        lines[cursor.row] = TerminalLine(cells: cells, isWrapped: lines[cursor.row].isWrapped)
    }

    public mutating func deleteCharacters(_ count: Int) {
        guard count > 0 else { return }
        var cells = lines[cursor.row].cells
        let amount = min(count, columns - cursor.column)
        cells.removeSubrange(cursor.column ..< (cursor.column + amount))
        var blank = TerminalCell.blank
        blank.attributes.background = attributes.background
        cells.append(contentsOf: Array(repeating: blank, count: amount))
        lines[cursor.row] = TerminalLine(cells: cells, isWrapped: lines[cursor.row].isWrapped)
    }

    public mutating func eraseCharacters(_ count: Int) {
        guard count > 0 else { return }
        let end = min(cursor.column + count - 1, columns - 1)
        lines[cursor.row].clear(from: cursor.column, through: end, attributes: attributes)
    }

    // MARK: - Resize

    /// Resizes the grid.
    ///
    /// Rows are added at the bottom, and removed from the top by pushing them into
    /// scrollback rather than discarding them — losing the top of the screen on every
    /// keyboard show/hide would be maddening.
    ///
    /// - Parameter reflowOnColumnChange: whether wrapped lines are re-wrapped to the new
    ///   width. True for the primary screen, where the history is the user's and must
    ///   survive a rotation intact. False for the alternate screen, whose content belongs
    ///   to a full-screen program that will redraw it from scratch — re-wrapping there
    ///   would scramble a layout the program is about to overwrite anyway.
    public mutating func resize(columns newColumns: Int, rows newRows: Int, reflowOnColumnChange: Bool = true) {
        let targetColumns = max(1, newColumns)
        let targetRows = max(1, newRows)
        guard targetColumns != columns || targetRows != rows else { return }

        if reflowOnColumnChange, targetColumns != columns {
            reflow(toColumns: targetColumns)
        } else {
            for index in lines.indices {
                lines[index].resize(to: targetColumns)
            }
            columns = targetColumns
        }

        if targetRows < rows {
            let excess = rows - targetRows
            let removable = min(excess, max(0, cursor.row - (targetRows - 1)))
            if removable > 0 {
                if scrollbackLimit > 0 {
                    scrollback.append(contentsOf: lines.prefix(removable))
                    if scrollback.count > scrollbackLimit {
                        scrollback.removeFirst(scrollback.count - scrollbackLimit)
                    }
                }
                lines.removeFirst(removable)
                cursor.row -= removable
            }
            if lines.count > targetRows {
                lines.removeLast(lines.count - targetRows)
            }
        } else if targetRows > rows {
            lines.append(contentsOf: (0 ..< (targetRows - rows)).map { _ in TerminalLine(width: targetColumns) })
        }

        rows = targetRows
        cursor.row = min(cursor.row, rows - 1)
        cursor.column = min(cursor.column, columns - 1)
        scrollTop = 0
        scrollBottom = rows - 1
        pendingWrap = false
    }

    /// Installs the result of a reflow. Kept separate so the reflow logic can live in
    /// its own file without making the screen's stored properties settable from outside.
    mutating func applyReflow(
        scrollback newScrollback: [TerminalLine],
        lines newLines: [TerminalLine],
        columns newColumns: Int,
        cursorRow: Int,
        cursorColumn: Int
    ) {
        scrollback = newScrollback
        lines = newLines
        columns = newColumns
        rows = newLines.count
        cursor.row = min(max(0, cursorRow), max(0, rows - 1))
        cursor.column = min(max(0, cursorColumn), max(0, columns - 1))
        scrollTop = 0
        scrollBottom = max(0, rows - 1)
        pendingWrap = false
    }

    /// Text of the visible screen, for tests and for accessibility.
    public var visibleText: String {
        lines.map(\.text).joined(separator: "\n")
    }
}
