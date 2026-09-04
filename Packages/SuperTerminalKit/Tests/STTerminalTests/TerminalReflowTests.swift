import Testing
@testable import STTerminal

/// Reflow is exercised constantly on a phone — every rotation, every keyboard
/// appearance, every Stage Manager drag — so these cover the cases that actually happen
/// rather than only the tidy ones.
@Suite("Reflow on resize")
struct TerminalReflowTests {
    private func emulator(columns: Int, rows: Int) -> TerminalEmulator {
        TerminalEmulator(columns: columns, rows: rows, scrollbackLimit: 200)
    }

    private func feed(_ emulator: inout TerminalEmulator, _ text: String) {
        _ = emulator.feed(Array(text.utf8))
        _ = emulator.flush()
    }

    @Test("Widening rejoins a line that had wrapped")
    func wideningRejoinsWrappedText() {
        var terminal = emulator(columns: 10, rows: 4)
        feed(&terminal, "abcdefghijklmnopqrst")
        // At 10 columns this is two rows; the first is a wrap, not a deliberate break.
        #expect(terminal.screen.lines[0].text == "abcdefghij")
        #expect(terminal.screen.lines[1].text == "klmnopqrst")

        terminal.resize(columns: 20, rows: 4)
        #expect(terminal.screen.lines[0].text == "abcdefghijklmnopqrst")
        #expect(terminal.screen.lines[1].text == "")
    }

    @Test("Narrowing re-wraps rather than truncating")
    func narrowingRewraps() {
        var terminal = emulator(columns: 20, rows: 4)
        feed(&terminal, "abcdefghijklmnopqrst")

        terminal.resize(columns: 10, rows: 4)
        // Truncating would silently destroy half the text.
        #expect(terminal.screen.lines[0].text == "abcdefghij")
        #expect(terminal.screen.lines[1].text == "klmnopqrst")
    }

    @Test("A deliberate line break is never joined to the next line")
    func hardBreaksSurvive() {
        var terminal = emulator(columns: 10, rows: 5)
        feed(&terminal, "one\r\ntwo\r\nthree")

        terminal.resize(columns: 40, rows: 5)
        // These lines ended because the program said so, not because they ran out of
        // room. Joining them would rewrite the program's output.
        let visible = terminal.screen.lines.map(\.text)
        #expect(visible[0] == "one")
        #expect(visible[1] == "two")
        #expect(visible[2] == "three")
    }

    @Test("Round-tripping a width leaves the content unchanged")
    func roundTripIsStable() {
        var terminal = emulator(columns: 24, rows: 6)
        feed(&terminal, "the quick brown fox jumps over the lazy dog\r\nsecond line\r\n")
        let before = (terminal.screen.scrollback + terminal.screen.lines).map(\.text).joined(separator: "\n")

        terminal.resize(columns: 12, rows: 6)
        terminal.resize(columns: 24, rows: 6)
        let after = (terminal.screen.scrollback + terminal.screen.lines).map(\.text).joined(separator: "\n")

        #expect(after.replacingOccurrences(of: "\n", with: "") == before.replacingOccurrences(of: "\n", with: ""))
    }

    @Test("A double-width character is never split across the new margin")
    func wideCharactersStayWhole() {
        var terminal = emulator(columns: 10, rows: 4)
        feed(&terminal, "ab中文测试的内容")

        terminal.resize(columns: 7, rows: 4)
        for line in terminal.screen.lines {
            // A continuation cell in column 0 would mean the left half was left behind on
            // the previous row.
            #expect(!line[0].isWideContinuation)
            if let last = line.cells.last, let character = last.character {
                #expect(CharacterWidth.of(character) == 1 || line.width >= 2)
            }
        }
        #expect(terminal.screen.visibleText.contains("中文"))
    }

    @Test("Attributes survive reflow")
    func attributesSurvive() {
        var terminal = emulator(columns: 10, rows: 4)
        feed(&terminal, "\u{1B}[31mredredredredred\u{1B}[0m")

        terminal.resize(columns: 20, rows: 4)
        let line = terminal.screen.lines[0]
        #expect(line[0].attributes.foreground == .indexed(1))
        #expect(line[14].attributes.foreground == .indexed(1))
    }

    @Test("The cursor stays with its text")
    func cursorFollowsContent() {
        var terminal = emulator(columns: 10, rows: 4)
        feed(&terminal, "abcdefghijklmno")
        #expect(terminal.screen.cursor.row == 1)
        #expect(terminal.screen.cursor.column == 5)

        terminal.resize(columns: 20, rows: 4)
        // The 15 characters now fit on one row, so the cursor belongs at column 15.
        #expect(terminal.screen.cursor.row == 0)
        #expect(terminal.screen.cursor.column == 15)
    }

    @Test("The alternate screen is not reflowed")
    func alternateScreenIsNotReflowed() {
        var terminal = emulator(columns: 20, rows: 4)
        feed(&terminal, "\u{1B}[?1049h")
        feed(&terminal, "abcdefghijklmnopqrst")

        terminal.resize(columns: 10, rows: 4)
        // A full-screen program owns this buffer and redraws it after SIGWINCH.
        // Re-wrapping would scramble a layout that is about to be overwritten.
        #expect(terminal.activeScreen.columns == 10)
        #expect(terminal.activeScreen.lines[1].text.isEmpty)
    }

    @Test("Reflow keeps scrollback within its limit")
    func reflowRespectsScrollbackLimit() {
        var terminal = TerminalEmulator(columns: 80, rows: 5, scrollbackLimit: 20)
        for index in 0 ..< 200 {
            feed(&terminal, "line \(index) with some text to make it long enough to wrap when narrow\r\n")
        }
        terminal.resize(columns: 20, rows: 5)
        // Narrowing multiplies the line count; an unbounded reflow is a memory bug.
        #expect(terminal.screen.scrollback.count <= 20)
    }
}
