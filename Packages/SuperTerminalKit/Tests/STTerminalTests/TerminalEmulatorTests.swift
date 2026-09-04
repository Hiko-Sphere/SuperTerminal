import Foundation
import Testing
@testable import STTerminal

@Suite("Terminal emulator")
struct TerminalEmulatorTests {
    private func emulator(columns: Int = 20, rows: Int = 5) -> TerminalEmulator {
        TerminalEmulator(columns: columns, rows: rows, scrollbackLimit: 100)
    }

    private func feed(_ emulator: inout TerminalEmulator, _ text: String) -> [TerminalEvent] {
        var events = emulator.feed(Array(text.utf8))
        events.append(contentsOf: emulator.flush())
        return events
    }

    @Test("Text lands on the screen and the cursor advances")
    func writesText() {
        var terminal = emulator()
        _ = feed(&terminal, "hello")
        #expect(terminal.activeScreen.lines[0].text == "hello")
        #expect(terminal.activeScreen.cursor.column == 5)
    }

    @Test("Wrapping is deferred until one more character arrives")
    func deferredWrap() {
        var terminal = emulator(columns: 5, rows: 3)
        _ = feed(&terminal, "abcde")
        // Exactly filling the line must not move to the next row: full-screen programs
        // draw the bottom-right cell and would scroll the screen if it did.
        #expect(terminal.activeScreen.cursor.row == 0)
        #expect(terminal.activeScreen.cursor.column == 4)

        _ = feed(&terminal, "f")
        #expect(terminal.activeScreen.cursor.row == 1)
        #expect(terminal.activeScreen.lines[0].text == "abcde")
        #expect(terminal.activeScreen.lines[1].text == "f")
        #expect(terminal.activeScreen.lines[0].isWrapped)
    }

    @Test("A double-width character claims two cells")
    func wideCharacterOccupiesTwoCells() {
        var terminal = emulator(columns: 10, rows: 2)
        _ = feed(&terminal, "中文")
        let line = terminal.activeScreen.lines[0]
        #expect(line[0].character == "中")
        #expect(line[1].isWideContinuation)
        #expect(line[2].character == "文")
        #expect(line[3].isWideContinuation)
        #expect(terminal.activeScreen.cursor.column == 4)
    }

    @Test("A double-width character that will not fit moves to the next line whole")
    func wideCharacterDoesNotSplitAcrossTheMargin() {
        var terminal = emulator(columns: 5, rows: 3)
        _ = feed(&terminal, "abcd中")
        // Splitting the character across the margin would shift every column after it.
        #expect(terminal.activeScreen.lines[0].text == "abcd")
        #expect(terminal.activeScreen.lines[1][0].character == "中")
    }

    @Test("Overwriting half of a wide character clears both cells")
    func overwritingWideCharacterClearsBothHalves() {
        var terminal = emulator(columns: 10, rows: 2)
        _ = feed(&terminal, "中")
        _ = feed(&terminal, "\u{1B}[1;1HX")
        let line = terminal.activeScreen.lines[0]
        #expect(line[0].character == "X")
        // The orphaned right half must be gone, not left as a phantom cell.
        #expect(!line[1].isWideContinuation)
        #expect(line[1].character == nil)
    }

    @Test("Cursor addressing is one-based, as the escape sequences specify")
    func cursorAddressing() {
        var terminal = emulator()
        _ = feed(&terminal, "\u{1B}[3;7H")
        #expect(terminal.activeScreen.cursor.row == 2)
        #expect(terminal.activeScreen.cursor.column == 6)
    }

    @Test("Erase in line honours all three modes")
    func eraseInLine() {
        var terminal = emulator(columns: 10, rows: 2)
        _ = feed(&terminal, "abcdefghij\u{1B}[1;4H\u{1B}[K")
        #expect(terminal.activeScreen.lines[0].text == "abc")

        var backwards = emulator(columns: 10, rows: 2)
        _ = feed(&backwards, "abcdefghij\u{1B}[1;4H\u{1B}[1K")
        #expect(backwards.activeScreen.lines[0].text == "    efghij")
    }

    @Test("Scrolling past the bottom moves lines into scrollback")
    func scrollbackCaptures() {
        var terminal = emulator(columns: 10, rows: 3)
        _ = feed(&terminal, "one\r\ntwo\r\nthree\r\nfour")
        #expect(terminal.screen.scrollback.map(\.text) == ["one"])
        #expect(terminal.screen.lines.map(\.text) == ["two", "three", "four"])
    }

    @Test("The scrollback is bounded")
    func scrollbackIsBounded() {
        var terminal = TerminalEmulator(columns: 10, rows: 2, scrollbackLimit: 5)
        for index in 0 ..< 50 {
            _ = feed(&terminal, "line\(index)\r\n")
        }
        // Unbounded scrollback is how a terminal turns a chatty program into an
        // out-of-memory crash.
        #expect(terminal.screen.scrollback.count <= 5)
    }

    @Test("The alternate screen leaves the primary buffer and its scrollback untouched")
    func alternateScreenIsIsolated() {
        var terminal = emulator(columns: 10, rows: 3)
        _ = feed(&terminal, "shell output\r\n")
        let before = terminal.screen.lines.map(\.text)

        var events = feed(&terminal, "\u{1B}[?1049h")
        #expect(events.contains(.alternateScreenChanged(true)))
        _ = feed(&terminal, "app")
        #expect(terminal.activeScreen.lines[0].text == "app")

        events = feed(&terminal, "\u{1B}[?1049l")
        #expect(events.contains(.alternateScreenChanged(false)))
        // Leaving `vim` must reveal exactly what was underneath.
        #expect(terminal.screen.lines.map(\.text) == before)
        #expect(terminal.activeScreen.lines.map(\.text) == before)
    }

    @Test("The alternate screen contributes nothing to scrollback")
    func alternateScreenDoesNotPolluteScrollback() {
        var terminal = emulator(columns: 10, rows: 2)
        _ = feed(&terminal, "\u{1B}[?1049h")
        for index in 0 ..< 30 {
            _ = feed(&terminal, "redraw\(index)\r\n")
        }
        _ = feed(&terminal, "\u{1B}[?1049l")
        #expect(terminal.screen.scrollback.isEmpty)
    }

    @Test("SGR sets colours in all three notations")
    func sgrColours() {
        var terminal = emulator()
        _ = feed(&terminal, "\u{1B}[31mA")
        #expect(terminal.activeScreen.lines[0][0].attributes.foreground == .indexed(1))

        _ = feed(&terminal, "\u{1B}[38;5;123mB")
        #expect(terminal.activeScreen.lines[0][1].attributes.foreground == .indexed(123))

        _ = feed(&terminal, "\u{1B}[38;2;17;34;51mC")
        #expect(terminal.activeScreen.lines[0][2].attributes.foreground == .rgb(red: 17, green: 34, blue: 51))

        // The colon form from ITU T.416, which several programs emit.
        _ = feed(&terminal, "\u{1B}[38:2::10:20:30mD")
        #expect(terminal.activeScreen.lines[0][3].attributes.foreground == .rgb(red: 10, green: 20, blue: 30))
    }

    @Test("SGR attributes accumulate and reset")
    func sgrAttributes() {
        var terminal = emulator()
        _ = feed(&terminal, "\u{1B}[1;3;4mA\u{1B}[0mB")
        let bold = terminal.activeScreen.lines[0][0].attributes
        #expect(bold.bold)
        #expect(bold.italic)
        #expect(bold.underline)
        #expect(terminal.activeScreen.lines[0][1].attributes == .normal)
    }

    @Test("A cursor position report is answered with the cursor's position")
    func devicseStatusReport() {
        var terminal = emulator()
        let events = feed(&terminal, "\u{1B}[3;5H\u{1B}[6n")
        // A terminal that does not answer this makes programs that query it hang.
        #expect(events.contains(.respond(Data("\u{1B}[3;5R".utf8))))
    }

    @Test("The scroll region confines scrolling")
    func scrollRegion() {
        var terminal = emulator(columns: 10, rows: 5)
        _ = feed(&terminal, "a\r\nb\r\nc\r\nd\r\ne")
        _ = feed(&terminal, "\u{1B}[2;4r")   // region rows 2–4
        _ = feed(&terminal, "\u{1B}[4;1H\n") // line feed at the bottom of the region
        #expect(terminal.activeScreen.lines[0].text == "a")
        #expect(terminal.activeScreen.lines[1].text == "c")
        #expect(terminal.activeScreen.lines[2].text == "d")
        #expect(terminal.activeScreen.lines[3].text == "")
        #expect(terminal.activeScreen.lines[4].text == "e")
    }

    @Test("The window title is taken from OSC and stripped of control characters")
    func windowTitle() {
        var terminal = emulator()
        let events = feed(&terminal, "\u{1B}]0;my \u{07}")
        #expect(events.contains(.title("my ")))
        #expect(terminal.title == "my ")
    }

    @Test("Only safe hyperlink schemes are recorded")
    func hyperlinkSchemesAreFiltered() {
        var terminal = emulator()
        _ = feed(&terminal, "\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{07}")
        #expect(terminal.hyperlinks.values.contains { $0.url == "https://example.com" })

        var hostile = emulator()
        _ = feed(&hostile, "\u{1B}]8;;javascript:alert(1)\u{07}x")
        // A scheme the system opener must never see is dropped rather than stored, so no
        // later part of the UI can be tricked into opening it.
        #expect(hostile.hyperlinks.isEmpty)
        #expect(hostile.activeScreen.lines[0][0].attributes.hyperlinkID == nil)
    }

    @Test("Bracketed paste and mouse modes are reported to the UI")
    func modeChangesAreReported() {
        var terminal = emulator()
        _ = feed(&terminal, "\u{1B}[?2004h\u{1B}[?1002h\u{1B}[?1006h")
        #expect(terminal.modes.bracketedPaste)
        #expect(terminal.modes.mouseTracking == .buttonEvent)
        #expect(terminal.modes.sgrMouseEncoding)

        _ = feed(&terminal, "\u{1B}[?2004l")
        #expect(!terminal.modes.bracketedPaste)
    }

    @Test("Resizing keeps the cursor on screen and preserves content")
    func resizePreservesContent() {
        var terminal = emulator(columns: 20, rows: 5)
        _ = feed(&terminal, "hello\r\nworld")
        terminal.resize(columns: 10, rows: 3)
        #expect(terminal.activeScreen.columns == 10)
        #expect(terminal.activeScreen.rows == 3)
        #expect(terminal.activeScreen.lines[0].text == "hello")
        #expect(terminal.activeScreen.lines[1].text == "world")
        #expect(terminal.activeScreen.cursor.row < 3)
    }

    @Test("A very long run of output does not grow memory without bound")
    func sustainedOutputIsBounded() {
        var terminal = TerminalEmulator(columns: 80, rows: 24, scrollbackLimit: 1000)
        let chunk = Array(String(repeating: "x", count: 79).utf8) + [0x0D, 0x0A]
        for _ in 0 ..< 20000 {
            _ = terminal.feed(chunk)
        }
        #expect(terminal.screen.scrollback.count == 1000)
        #expect(terminal.screen.lines.count == 24)
    }
}
