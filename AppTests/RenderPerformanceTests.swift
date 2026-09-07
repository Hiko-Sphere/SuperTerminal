import STTerminal
import UIKit
import XCTest
@testable import ApexTerminal

/// Measures the cost of actually drawing a terminal.
///
/// The emulator's throughput is measured in the package; this measures the other half —
/// Core Text laying out and drawing the grid. Together they are what "does it feel fast?"
/// reduces to, and both are measured rather than asserted.
///
/// XCTest's `measure` is used rather than Instruments because it produces a number on
/// every run, in CI as well as on a desk, and it fails when the number regresses. An
/// Instruments trace is a better tool for finding *why* something is slow; this is the
/// tool for noticing that it became slow.
@MainActor
final class RenderPerformanceTests: XCTestCase {
    /// A full screen of realistic output: text, colour changes, and some CJK.
    private func makeScreen(columns: Int, rows: Int) -> TerminalScreen {
        var emulator = TerminalEmulator(columns: columns, rows: rows, scrollbackLimit: 100)
        for row in 0 ..< rows {
            var line = "\u{1B}[3\(row % 8)m"
            line += "line \(row) "
            line += String(repeating: "abcdefghij ", count: max(1, (columns - 20) / 11))
            if row % 5 == 0 { line += "中文测试" }
            line += "\u{1B}[0m\r\n"
            _ = emulator.feed(Array(line.utf8))
        }
        _ = emulator.flush()
        return emulator.activeScreen
    }

    private func makeView(columns: Int, rows: Int) -> TerminalRenderView {
        let view = TerminalRenderView()
        view.theme = .midnight
        view.fontSize = 13
        let metrics = view.metrics
        view.frame = CGRect(
            x: 0,
            y: 0,
            width: metrics.cellWidth * CGFloat(columns),
            height: metrics.cellHeight * CGFloat(rows)
        )
        view.update(screen: makeScreen(columns: columns, rows: rows))
        return view
    }

    /// Draws the view into a bitmap by calling `draw(_:)` directly.
    ///
    /// `layer.render(in:)` was tried first and measured almost the same for every input,
    /// because the fixed per-frame cost of the image renderer swamped the drawing. Calling
    /// `draw(_:)` is what actually runs on screen.
    private func render(_ view: TerminalRenderView) {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        _ = renderer.image { context in
            UIGraphicsPushContext(context.cgContext)
            view.draw(view.bounds)
            UIGraphicsPopContext()
        }
    }

    func testDrawingAPhoneSizedScreen() {
        let view = makeView(columns: 80, rows: 24)
        reportFrameTime("80x24", view: view)
        measure {
            for _ in 0 ..< 10 { render(view) }
        }
    }

    func testDrawingAnIPadSizedScreen() {
        // A 13-inch iPad in landscape at 13 pt is roughly this.
        let view = makeView(columns: 200, rows: 55)
        reportFrameTime("200x55", view: view)
        measure {
            for _ in 0 ..< 10 { render(view) }
        }
    }

    /// Prints a per-frame figure and fails if a full redraw could not keep up with a
    /// 60 Hz display.
    ///
    /// A terminal rarely redraws every frame — output arrives in bursts and only dirty
    /// rows change — so this is a ceiling rather than a steady-state cost. But if a full
    /// redraw cannot fit in a frame, a burst of output will visibly stutter.
    private func reportFrameTime(_ label: String, view: TerminalRenderView) {
        for _ in 0 ..< 5 { render(view) }  // warm the font and glyph caches
        let iterations = 60
        let elapsed = time { for _ in 0 ..< iterations { render(view) } }
        let milliseconds = elapsed / Double(iterations) * 1000
        print("render \(label): \(String(format: "%.2f", milliseconds)) ms per full redraw")
        XCTAssertLessThan(
            milliseconds, 16.6,
            "a full redraw of \(label) took \(milliseconds) ms, which cannot keep up with a 60 Hz display"
        )
    }

    /// Run coalescing is the renderer's main optimisation: adjacent cells sharing
    /// attributes become one Core Text line rather than one per cell.
    ///
    /// Asserted on the run count rather than on elapsed time. The first version of this
    /// test compared wall-clock between a uniform row and a hundred-colour row, and the
    /// two measured within 1% of each other — the fixed per-frame cost dominated, so the
    /// test passed or failed at random and proved nothing either way.
    func testRunCoalescingProducesOneRunPerAttributeSpan() {
        let view = TerminalRenderView()

        var uniform = TerminalEmulator(columns: 200, rows: 1, scrollbackLimit: 0)
        _ = uniform.feed(Array(String(repeating: "x", count: 200).utf8))
        _ = uniform.flush()
        let uniformRuns = view.coalesce(uniform.activeScreen.lines[0])
        XCTAssertEqual(uniformRuns.count, 1, "200 identically styled cells should be one run")

        var alternating = TerminalEmulator(columns: 200, rows: 1, scrollbackLimit: 0)
        var text = ""
        for index in 0 ..< 100 {
            text += "\u{1B}[3\(index % 8)mx"
        }
        _ = alternating.feed(Array(text.utf8))
        _ = alternating.flush()
        let alternatingRuns = view.coalesce(alternating.activeScreen.lines[0])
        // Eight colours cycling means a new run at every character, plus the untouched
        // tail of the line.
        XCTAssertGreaterThanOrEqual(alternatingRuns.count, 100)
        XCTAssertEqual(alternatingRuns.map(\.width).reduce(0, +), 200, "runs must cover every cell exactly once")
    }

    /// A wide character's continuation cell has no glyph but must still be covered, or the
    /// background fill would stop halfway through it.
    func testRunsCoverWideCharactersWithoutDuplicatingThem() {
        let view = TerminalRenderView()
        var emulator = TerminalEmulator(columns: 20, rows: 1, scrollbackLimit: 0)
        _ = emulator.feed(Array("中文ab".utf8))
        _ = emulator.flush()

        let runs = view.coalesce(emulator.activeScreen.lines[0])
        XCTAssertEqual(runs.map(\.width).reduce(0, +), 20, "runs must cover the whole line")
        let text = runs.map(\.text).joined()
        XCTAssertTrue(text.hasPrefix("中文ab"), "each character should appear once, got \(text.prefix(6))")
    }

    private func time(_ body: () -> Void) -> Double {
        let start = DispatchTime.now()
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}
