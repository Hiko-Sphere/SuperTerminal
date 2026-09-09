import Foundation
import Testing

@testable import STTerminal

/// The parser's contract, put under fire (D-069).
///
/// `TerminalParser` claims that no byte sequence can wedge it: every state has a defined
/// transition for every byte, so hostile or corrupt output degrades to visible garbage rather
/// than to a hang, an over-read or unbounded growth. That claim was written down and reasoned
/// about; here it is *tested*, by throwing bytes at it until something breaks.
///
/// The random numbers come from a seeded generator written out here rather than from the
/// system's, so a failure is reproducible: the seed is in the test and the same bytes come
/// back every run. A fuzz test that cannot be re-run is a rumour.
@Suite("Fuzzed input")
struct FuzzTests {
    /// xorshift64*, which is small enough to read and good enough to shuffle bytes.
    struct Seeded: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 2_685_821_657_736_338_717
        }
    }

    /// What must be true of a screen no matter what was fed to it.
    private func check(_ emulator: TerminalEmulator, columns: Int, rows: Int, seed: UInt64) {
        let screen = emulator.activeScreen
        #expect(screen.columns == columns, "seed \(seed): the width changed on its own")
        #expect(screen.rows == rows, "seed \(seed): the height changed on its own")
        #expect(screen.lines.count == rows, "seed \(seed): the line count left the screen")
        #expect(screen.lines.allSatisfy { $0.width == columns }, "seed \(seed): a line is the wrong width")
        #expect((0 ..< rows).contains(screen.cursor.row), "seed \(seed): the cursor left the screen")
        #expect((0 ..< columns).contains(screen.cursor.column), "seed \(seed): the cursor left the row")
        #expect(screen.scrollback.count <= screen.scrollbackLimit, "seed \(seed): the scrollback grew past its limit")
        #expect(screen.images.byteCount <= TerminalImageStore.maximumBytes, "seed \(seed): the pictures grew past their limit")
    }

    @Test("Random bytes cannot wedge the terminal", arguments: [UInt64(1), 20_260_909, 0xDEAD_BEEF])
    func randomBytes(seed: UInt64) {
        var random = Seeded(seed: seed)
        var emulator = TerminalEmulator(columns: 80, rows: 24, scrollbackLimit: 200)
        var responded = 0
        var fed = 0
        for _ in 0 ..< 500 {
            let count = Int.random(in: 1 ... 4096, using: &random)
            let bytes = (0 ..< count).map { _ in UInt8.random(in: 0 ... 255, using: &random) }
            fed += bytes.count
            for event in emulator.feed(bytes) {
                if case let .respond(data) = event { responded += data.count }
            }
        }
        _ = emulator.flush()
        check(emulator, columns: 80, rows: 24, seed: seed)
        // A megabyte or so of noise, so "it passed" is not "it did nothing".
        #expect(fed > 500_000, "seed \(seed)")
        // And noise must not turn into a stream of answers: the emulator caps what a single
        // write can produce, and nothing here should approach even that.
        #expect(responded < 500 * TerminalEmulator.maximumPendingResponseBytes, "seed \(seed)")
    }

    @Test("Sequences that look real cannot wedge it either", arguments: [UInt64(7), 4_242_424_242])
    func structuredNoise(seed: UInt64) {
        // Random bytes rarely reach the interesting code: a byte is a CSI introducer once in
        // 256, and a well-formed one much less often than that. These are built from real
        // introducers with random innards, which is where a parser actually breaks.
        var random = Seeded(seed: seed)
        var emulator = TerminalEmulator(columns: 100, rows: 30, scrollbackLimit: 100)
        let introducers = ["\u{1B}[", "\u{1B}]", "\u{1B}P", "\u{1B}_", "\u{1B}^", "\u{1B}X", "\u{1B}"]
        let finals = Array("ABCDEFGHJKLMPSTXhlmnpqrstuvwxyz@`~")
        let terminators = ["\u{07}", "\u{1B}\\", "", "\u{18}", "\u{1A}"]
        var answered = 0

        for _ in 0 ..< 400 {
            var text = ""
            for _ in 0 ..< Int.random(in: 1 ... 20, using: &random) {
                text += introducers.randomElement(using: &random)!
                for _ in 0 ..< Int.random(in: 0 ... 12, using: &random) {
                    text.append(Character(UnicodeScalar(UInt8.random(in: 0x20 ... 0x7E, using: &random))))
                }
                text.append(finals.randomElement(using: &random)!)
                text += terminators.randomElement(using: &random)!
            }
            for event in emulator.feed(Array(text.utf8)) {
                if case .respond = event { answered += 1 }
            }
        }
        _ = emulator.flush()
        check(emulator, columns: 100, rows: 30, seed: seed)
        // Sequences built this way reach the code that answers — device attributes, cursor
        // position reports, DECRQM. If none of them did, the generator would be producing
        // something the parser throws away, and the suite would be green for the wrong
        // reason.
        #expect(answered > 0, "seed \(seed): nothing here reached a sequence the terminal answers")
    }

    @Test("Resizing under fire keeps the screen consistent", arguments: [UInt64(99), 12_345])
    func resizingWhileFed(seed: UInt64) {
        var random = Seeded(seed: seed)
        var size = (columns: 80, rows: 24)
        var emulator = TerminalEmulator(columns: size.columns, rows: size.rows, scrollbackLimit: 100)
        for step in 0 ..< 200 {
            let count = Int.random(in: 1 ... 512, using: &random)
            _ = emulator.feed((0 ..< count).map { _ in UInt8.random(in: 0 ... 255, using: &random) })
            // Park the cursor in the far corner before resizing. Random bytes rarely leave it
            // anywhere interesting, and the corner is where a screen that shrinks without
            // bringing the cursor with it shows itself — checked by deleting that clamp and
            // watching this fail.
            _ = emulator.feed(Array("\u{1B}[9999;9999H".utf8))
            check(emulator, columns: size.columns, rows: size.rows, seed: seed)
            if step % 5 == 0 {
                size = (
                    columns: Int.random(in: 2 ... 200, using: &random),
                    rows: Int.random(in: 2 ... 60, using: &random)
                )
                emulator.resize(columns: size.columns, rows: size.rows)
                check(emulator, columns: size.columns, rows: size.rows, seed: seed)
            }
            if step % 7 == 0 {
                // Height only. A change of width rewraps, and rewrapping decides where the
                // cursor goes on its own — so a screen that shrinks in *height* without
                // bringing the cursor with it is only reachable this way. Checked by
                // deleting that clamp and watching this fail.
                size.rows = Int.random(in: 2 ... 60, using: &random)
                emulator.resize(columns: size.columns, rows: size.rows)
                check(emulator, columns: size.columns, rows: size.rows, seed: seed)
            }
        }
        _ = emulator.flush()
    }

    @Test("A picture protocol under fire draws nothing rather than crashing", arguments: [UInt64(5)])
    func fuzzedGraphics(seed: UInt64) {
        var random = Seeded(seed: seed)
        var emulator = TerminalEmulator(columns: 80, rows: 24, scrollbackLimit: 50)
        emulator.cellSize = TerminalEmulator.CellSize(width: 8, height: 16)
        let openers = ["\u{1B}P0;0;0q", "\u{1B}_G", "\u{1B}]1337;File=inline=1:"]
        for _ in 0 ..< 300 {
            var text = openers.randomElement(using: &random)!
            for _ in 0 ..< Int.random(in: 0 ... 400, using: &random) {
                text.append(Character(UnicodeScalar(UInt8.random(in: 0x20 ... 0x7E, using: &random))))
            }
            text += ["\u{1B}\\", "\u{07}", ""].randomElement(using: &random)!
            _ = emulator.feed(Array(text.utf8))
        }
        _ = emulator.flush()
        check(emulator, columns: 80, rows: 24, seed: seed)
    }
}
