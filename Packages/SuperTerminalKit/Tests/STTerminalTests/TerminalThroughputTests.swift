import Foundation
import Testing
@testable import STTerminal

/// Measures how fast the emulator can consume output, and asserts a floor.
///
/// The point is not the number but the floor: a change that halves throughput should fail
/// here rather than surface months later as "the terminal feels sluggish".
///
/// The floors differ by configuration because a Debug build is genuinely two to three
/// times slower — `swift test` runs Debug by default, so a single Release-level threshold
/// would either fail every ordinary run or be so low it caught nothing in Release. Each
/// floor sits at roughly half of what this machine measures, leaving room for a slower CI
/// runner while still catching a real regression.
@Suite("Emulator throughput", .serialized)
struct TerminalThroughputTests {
    /// Scales a Release-calibrated floor down for Debug.
    private func floor(release: Double) -> Double {
        #if DEBUG
        release / 3
        #else
        release
        #endif
    }

    /// Runs `body` and returns megabytes per second.
    private func measureThroughput(bytes: Int, _ body: () -> Void) -> Double {
        let start = DispatchTime.now()
        body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        return (Double(bytes) / 1_048_576) / max(elapsed, 0.000_001)
    }

    @Test("Plain text is consumed at a usable rate")
    func plainTextThroughput() {
        var terminal = TerminalEmulator(columns: 120, rows: 40, scrollbackLimit: 5000)
        let line = Data((String(repeating: "x", count: 119) + "\r\n").utf8)
        let iterations = 20_000
        let total = line.count * iterations

        let rate = measureThroughput(bytes: total) {
            for _ in 0 ..< iterations {
                _ = terminal.feed(line)
            }
        }
        print("plain text: \(String(format: "%.1f", rate)) MB/s")
        // Measured at ~14.7 MB/s in Release on an Apple silicon Mac — about 118 Mbit of
        // continuous output, far more than an interactive SSH session delivers and far
        // more than a person can read. The floor is set near half of that, because a CI
        // runner is slower than a desk and a flaky performance gate gets ignored.
        #expect(rate > floor(release: 7), "plain text throughput was \(rate) MB/s")
    }

    @Test("An array of bytes is consumed as fast as Data")
    func arrayThroughputMatchesData() {
        // `feed` is public and takes any sequence of bytes. Arrays used to be far slower
        // than `Data` through it — every byte went through a generic iterator call — and
        // because these benchmarks fed arrays, the published figures understated what the
        // app actually got by more than half.
        //
        // Asserted as a *ratio* measured in the same run rather than against an absolute
        // floor: the two paths should cost the same, and that stays true on a slow CI
        // runner where any fixed number would either be flaky or too loose to catch the
        // regression it exists for.
        let line = String(repeating: "w", count: 119) + "\r\n"
        let iterations = 20_000

        var dataTerminal = TerminalEmulator(columns: 120, rows: 40, scrollbackLimit: 5000)
        let asData = Data(line.utf8)
        let dataRate = measureThroughput(bytes: asData.count * iterations) {
            for _ in 0 ..< iterations { _ = dataTerminal.feed(asData) }
        }

        var arrayTerminal = TerminalEmulator(columns: 120, rows: 40, scrollbackLimit: 5000)
        let asArray = Array(line.utf8)
        let arrayRate = measureThroughput(bytes: asArray.count * iterations) {
            for _ in 0 ..< iterations { _ = arrayTerminal.feed(asArray) }
        }

        let ratio = arrayRate / dataRate
        print("array vs Data: \(String(format: "%.2f", ratio))×")
        #expect(ratio > 0.7, "arrays ran at \(arrayRate) MB/s against \(dataRate) MB/s for Data")
    }

    @Test("Heavily coloured output stays fast")
    func colouredThroughput() {
        var terminal = TerminalEmulator(columns: 120, rows: 40, scrollbackLimit: 5000)
        // Per-character colour changes are the worst realistic case — syntax highlighting,
        // `ls --color`, a progress bar redrawing.
        var line = ""
        for index in 0 ..< 100 {
            line += "\u{1B}[38;5;\(index % 256)m#"
        }
        line += "\u{1B}[0m\r\n"
        let bytes = Data(line.utf8)
        let iterations = 5000

        let rate = measureThroughput(bytes: bytes.count * iterations) {
            for _ in 0 ..< iterations {
                _ = terminal.feed(bytes)
            }
        }
        print("coloured: \(String(format: "%.1f", rate)) MB/s")
        // Measured at ~12.7 MB/s in Release. Coloured output is faster per byte than
        // plain text because the escape sequences are cheaper to parse than characters
        // are to place on the grid.
        #expect(rate > floor(release: 15), "coloured throughput was \(rate) MB/s")
    }

    @Test("CJK output stays fast")
    func wideCharacterThroughput() {
        var terminal = TerminalEmulator(columns: 120, rows: 40, scrollbackLimit: 5000)
        let bytes = Data((String(repeating: "中文测试", count: 15) + "\r\n").utf8)
        let iterations = 10_000

        let rate = measureThroughput(bytes: bytes.count * iterations) {
            for _ in 0 ..< iterations {
                _ = terminal.feed(bytes)
            }
        }
        print("CJK: \(String(format: "%.1f", rate)) MB/s")
        // Measured at ~8 MB/s in Release. Wide characters cost more per character but
        // fewer characters fill a line.
        #expect(rate > floor(release: 7), "CJK throughput was \(rate) MB/s")
    }

    @Test("Memory stays bounded under sustained output")
    func memoryIsBounded() {
        var terminal = TerminalEmulator(columns: 200, rows: 50, scrollbackLimit: 5000)
        let line = Data((String(repeating: "y", count: 199) + "\r\n").utf8)
        for _ in 0 ..< 100_000 {
            _ = terminal.feed(line)
        }
        // 100 000 lines through a 5 000-line buffer: what is retained is the limit, not
        // the history. Getting this wrong turns a chatty program into a crash.
        #expect(terminal.screen.scrollback.count == 5000)
        #expect(terminal.screen.lines.count == 50)
    }

    @Test("Reflow of a full scrollback completes promptly")
    func reflowIsFastEnoughForRotation() {
        var terminal = TerminalEmulator(columns: 120, rows: 40, scrollbackLimit: 5000)
        let line = Data((String(repeating: "z", count: 119) + "\r\n").utf8)
        for _ in 0 ..< 6000 {
            _ = terminal.feed(line)
        }

        let start = DispatchTime.now()
        terminal.resize(columns: 60, rows: 40)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        print("reflow of 5000 scrollback lines: \(String(format: "%.0f", elapsed * 1000)) ms")
        // Reflow runs on rotation and on every keyboard appearance, so it has to finish
        // inside an animation rather than after it. Measured at ~18 ms in Release and
        // ~55 ms in Debug for a full 5 000-line scrollback.
        #expect(elapsed < 0.5, "reflow took \(elapsed)s")
    }
}
