import Foundation
import Testing

@testable import STTmux

/// tmux window layouts, against strings a real tmux 3.3a sent.
@Suite("tmux layout")
struct TmuxLayoutTests {
    @Test("A single pane")
    func onePane() throws {
        // From `list-windows` on a fresh session.
        let layout = try TmuxLayout.parse("b25d,80x24,0,0,0")
        #expect(layout == .pane(TmuxLayoutFrame(width: 80, height: 24, x: 0, y: 0), TmuxPaneID(0)))
        #expect(layout.panes.map(\.id) == [TmuxPaneID(0)])
    }

    @Test("Two panes stacked, which is what split-window makes")
    func stacked() throws {
        // Captured after `split-window`: `[` is top-and-bottom, and the second pane starts
        // at y=13 because the divider takes a row.
        let layout = try TmuxLayout.parse("c195,80x24,0,0[80x12,0,0,0,80x11,0,13,1]")
        guard case let .topBottom(frame, children) = layout else {
            Issue.record("expected a stack, got \(layout)")
            return
        }
        #expect(frame == TmuxLayoutFrame(width: 80, height: 24, x: 0, y: 0))
        #expect(children == [
            .pane(TmuxLayoutFrame(width: 80, height: 12, x: 0, y: 0), TmuxPaneID(0)),
            .pane(TmuxLayoutFrame(width: 80, height: 11, x: 0, y: 13), TmuxPaneID(1)),
        ])
    }

    @Test("Side by side, and nested")
    func nested() throws {
        // `{` is left-and-right. The checksum is computed here rather than copied so the
        // test states the layout it means and cannot disagree with itself.
        let body = "80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}"
        let text = String(format: "%04x", TmuxLayout.checksum(of: body)) + "," + body
        let layout = try TmuxLayout.parse(text)
        #expect(layout.panes.map(\.id) == [TmuxPaneID(0), TmuxPaneID(1), TmuxPaneID(2)])
        #expect(layout.panes.map(\.frame.x) == [0, 41, 41])
        #expect(layout.panes.map(\.frame.y) == [0, 0, 13])
    }

    @Test("A layout whose checksum does not match is refused")
    func rejectsABadChecksum() {
        // Not pedantry: a layout that arrived corrupt would otherwise be drawn as a
        // plausible arrangement that is not the one the server has, and every pane after it
        // would show the wrong thing.
        #expect(throws: TmuxLayoutError.checksumMismatch(sent: "0000", computed: "b25d")) {
            try TmuxLayout.parse("0000,80x24,0,0,0")
        }
    }

    @Test("Malformed layouts are refused rather than half-read", arguments: [
        "b25d,80x24,0,0",              // no pane id and no children
        "80x24,0,0,0",                 // no checksum
        "c195,80x24,0,0[80x12,0,0,0",  // unclosed
    ])
    func rejectsMalformed(text: String) {
        #expect(throws: (any Error).self) { try TmuxLayout.parse(text) }
    }

    @Test("The checksum is tmux's own")
    func checksumMatchesTmux() {
        // Both of these were produced by a real server; if this function were anything else
        // every layout tmux sends would be rejected.
        #expect(String(format: "%04x", TmuxLayout.checksum(of: "80x24,0,0,0")) == "b25d")
        #expect(String(format: "%04x", TmuxLayout.checksum(of: "80x24,0,0[80x12,0,0,0,80x11,0,13,1]")) == "c195")
    }
}
