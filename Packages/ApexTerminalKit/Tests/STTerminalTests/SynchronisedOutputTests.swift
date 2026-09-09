import Foundation
import Testing

@testable import STTerminal

/// DEC 2026 and DEC 1004, and the question programs ask before using them (D-062).
@Suite("Synchronised output and focus reporting")
struct SynchronisedOutputTests {
    private func feed(_ text: String, into emulator: inout TerminalEmulator) -> [TerminalEvent] {
        emulator.feed(Array(text.utf8))
    }

    @Test("A program can hold the screen while it draws a frame")
    func synchronisedOutput() {
        var emulator = TerminalEmulator(columns: 80, rows: 24)
        _ = feed("\u{1B}[?2026h", into: &emulator)
        #expect(emulator.modes.synchronisedOutput, "begin means do not draw yet")

        // What arrives in between is still applied — the mode is about *showing*, not
        // about buffering — so the screen is correct the moment it is allowed to be seen.
        // `flush` because the parser holds the last character until it knows nothing
        // combines with it, which is what makes a grapheme that arrives in two chunks come
        // out as one character.
        _ = feed("hello", into: &emulator)
        _ = emulator.flush()
        #expect(emulator.activeScreen.visibleText.contains("hello"))

        _ = feed("\u{1B}[?2026l", into: &emulator)
        #expect(!emulator.modes.synchronisedOutput)
    }

    @Test("Focus reporting is a mode the program turns on")
    func focusReporting() {
        var emulator = TerminalEmulator(columns: 80, rows: 24)
        #expect(!emulator.modes.focusReporting, "off until asked for")
        _ = feed("\u{1B}[?1004h", into: &emulator)
        #expect(emulator.modes.focusReporting)
        _ = feed("\u{1B}[?1004l", into: &emulator)
        #expect(!emulator.modes.focusReporting)
    }

    @Test("DECRQM says whether a mode is supported, and whether it is on")
    func reportsModes() {
        var emulator = TerminalEmulator(columns: 80, rows: 24)

        // Reset: 2. This is what a program reads before deciding to use the mode at all.
        var events = feed("\u{1B}[?2026$p", into: &emulator)
        #expect(events == [.respond(Data("\u{1B}[?2026;2$y".utf8))])

        _ = feed("\u{1B}[?2026h", into: &emulator)
        events = feed("\u{1B}[?2026$p", into: &emulator)
        #expect(events == [.respond(Data("\u{1B}[?2026;1$y".utf8))], "set: 1")

        // A mode this terminal does not implement answers 0 — "no such mode here" — which
        // is what tells a program not to send it rather than to hope.
        events = feed("\u{1B}[?9999$p", into: &emulator)
        #expect(events == [.respond(Data("\u{1B}[?9999;0$y".utf8))])
    }

    @Test("The modes programs actually query all answer")
    func reportsTheUsualModes() {
        var emulator = TerminalEmulator(columns: 80, rows: 24)
        for mode in [1, 6, 7, 25, 1000, 1002, 1003, 1004, 1006, 1049, 2004, 2026] {
            let events = feed("\u{1B}[?\(mode)$p", into: &emulator)
            guard case let .respond(data)? = events.first else {
                Issue.record("mode \(mode) was not answered")
                continue
            }
            let reply = String(decoding: data, as: UTF8.self)
            #expect(reply.hasPrefix("\u{1B}[?\(mode);"), "got \(reply) for \(mode)")
            #expect(!reply.hasSuffix("0$y"), "mode \(mode) should be known")
        }
    }
}
