import Testing
@testable import STTerminal

@Suite("Selection and search")
struct TerminalTextAccessTests {
    private func emulator(columns: Int = 20, rows: Int = 5) -> TerminalEmulator {
        TerminalEmulator(columns: columns, rows: rows, scrollbackLimit: 100)
    }

    private func feed(_ emulator: inout TerminalEmulator, _ text: String) {
        _ = emulator.feed(Array(text.utf8))
        _ = emulator.flush()
    }

    @Test("A selection within one line returns exactly those characters")
    func singleLineSelection() {
        var terminal = emulator()
        feed(&terminal, "hello world")
        let range = TerminalRange(
            start: TerminalPosition(row: 0, column: 6),
            end: TerminalPosition(row: 0, column: 10)
        )
        #expect(terminal.screen.text(in: range) == "world")
    }

    @Test("A selection across a soft wrap has no newline inserted")
    func softWrapIsNotBrokenByCopy() {
        var terminal = emulator(columns: 10, rows: 4)
        feed(&terminal, "echo hello-world-from-here")
        let range = TerminalRange(
            start: TerminalPosition(row: 0, column: 0),
            end: TerminalPosition(row: 2, column: 9)
        )
        // A newline here would turn one pasted command into two, and the shell would run
        // the first half.
        #expect(terminal.screen.text(in: range) == "echo hello-world-from-here")
    }

    @Test("A deliberate line break is preserved when copying")
    func hardBreaksArePreserved() {
        var terminal = emulator()
        feed(&terminal, "first\r\nsecond\r\n")
        let range = TerminalRange(
            start: TerminalPosition(row: 0, column: 0),
            end: TerminalPosition(row: 1, column: 19)
        )
        #expect(terminal.screen.text(in: range) == "first\nsecond")
    }

    @Test("A block selection takes the same columns from every row")
    func blockSelection() {
        var terminal = emulator()
        feed(&terminal, "aaXXbb\r\nccXXdd\r\neeXXff")
        let range = TerminalRange(
            start: TerminalPosition(row: 0, column: 2),
            end: TerminalPosition(row: 2, column: 3),
            isBlock: true
        )
        // Copying one column out of tabular output is the whole point of block selection.
        #expect(terminal.screen.text(in: range) == "XX\nXX\nXX")
    }

    @Test("Copying a wide character does not duplicate it")
    func wideCharactersCopyOnce() {
        var terminal = emulator()
        feed(&terminal, "中文abc")
        let range = TerminalRange(
            start: TerminalPosition(row: 0, column: 0),
            end: TerminalPosition(row: 0, column: 6)
        )
        // The continuation cell must contribute nothing, or every CJK character would be
        // copied twice.
        #expect(terminal.screen.text(in: range) == "中文abc")
    }

    @Test("Selection reaches into scrollback")
    func selectionIncludesScrollback() {
        var terminal = emulator(columns: 20, rows: 3)
        feed(&terminal, "one\r\ntwo\r\nthree\r\nfour\r\nfive")
        #expect(terminal.screen.scrollback.count == 2)

        let range = TerminalRange(
            start: TerminalPosition(row: 0, column: 0),
            end: TerminalPosition(row: 1, column: 19)
        )
        #expect(terminal.screen.text(in: range) == "one\ntwo")
    }

    @Test("A double-tap range covers the whole wrapped line")
    func logicalLineRangeFollowsWraps() {
        var terminal = emulator(columns: 10, rows: 4)
        feed(&terminal, "abcdefghijklmnopqrstuvwxy")
        guard let range = terminal.screen.logicalLineRange(containing: 1) else {
            Issue.record("expected a logical line range")
            return
        }
        #expect(range.start.row == 0)
        #expect(range.end.row == 2)
        #expect(terminal.screen.text(in: range) == "abcdefghijklmnopqrstuvwxy")
    }

    @Test("Search finds text and reports where it is")
    func searchFindsText() {
        var terminal = emulator()
        feed(&terminal, "alpha\r\nbeta\r\ngamma beta\r\n")
        let matches = terminal.screen.search(for: "beta")
        #expect(matches.count == 2)
        #expect(matches[0].range.start.row == 1)
        #expect(matches[1].range.start.column == 6)
    }

    @Test("Search is case-insensitive by default and exact when asked")
    func searchCaseSensitivity() {
        var terminal = emulator()
        feed(&terminal, "Error: something\r\nerror: other\r\n")
        #expect(terminal.screen.search(for: "error").count == 2)
        #expect(terminal.screen.search(for: "error", caseSensitive: true).count == 1)
    }

    @Test("Search finds a term split across a wrap")
    func searchCrossesWraps() {
        var terminal = emulator(columns: 8, rows: 4)
        feed(&terminal, "abcdefconnectionrefused")
        // "connection" straddles the wrap, which is precisely when a person cannot spot it
        // by eye and needs search to work.
        let matches = terminal.screen.search(for: "connectionrefused")
        #expect(matches.count == 1)
        #expect(matches.first?.range.start.row == 0)
    }

    @Test("Search results are capped")
    func searchIsBounded() {
        var terminal = TerminalEmulator(columns: 20, rows: 4, scrollbackLimit: 2000)
        for _ in 0 ..< 800 {
            feed(&terminal, "match\r\n")
        }
        #expect(terminal.screen.search(for: "match", limit: 100).count == 100)
    }
}
