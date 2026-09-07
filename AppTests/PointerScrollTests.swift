import Foundation
import STTerminal
import Testing
import UIKit
@testable import ApexTerminal

/// Scrolling arithmetic and the interactions that decide whether a pointer can select
/// (D-025). The gestures themselves cannot be driven from XCUITest on iOS, so what a
/// device would exercise is separated into a value type and asserted directly.
@Suite struct PointerScrollTests {
    private let cellHeight: CGFloat = 16

    @Test("A wheel notch smaller than a row still scrolls, once enough notches arrive")
    func notchesAccumulateBetweenGestures() {
        var accumulator = ScrollAccumulator()
        // iPadOS delivers one notch as a whole gesture, and a notch is usually shorter
        // than a line: each one on its own rounds to nothing.
        #expect(accumulator.consume(translation: 10, cellHeight: cellHeight) == 0)
        // The second notch crosses the line. Keeping the remainder between gestures is
        // the whole fix: zeroing it per gesture is why a mouse wheel did nothing.
        #expect(accumulator.consume(translation: 10, cellHeight: cellHeight) == 1)
        #expect(accumulator.consume(translation: 10, cellHeight: cellHeight) == 0)
        #expect(accumulator.consume(translation: 10, cellHeight: cellHeight) == 1)
    }

    @Test("A continuous drag scrolls by whole rows and keeps the remainder")
    func continuousMovement() {
        var accumulator = ScrollAccumulator()
        #expect(accumulator.consume(translation: 40, cellHeight: cellHeight) == 2)
        // 8 points were left over, so 8 more make the next row.
        #expect(accumulator.consume(translation: 8, cellHeight: cellHeight) == 1)
    }

    @Test("Direction is preserved, and a cancelled gesture forgets what it had")
    func directionAndReset() {
        var accumulator = ScrollAccumulator()
        #expect(accumulator.consume(translation: -32, cellHeight: cellHeight) == -2)
        #expect(accumulator.consume(translation: 10, cellHeight: cellHeight) == 0)
        accumulator.reset()
        #expect(accumulator.consume(translation: 10, cellHeight: cellHeight) == 0, "the 10 points before the reset are gone")
        #expect(accumulator.consume(translation: 6, cellHeight: cellHeight) == 1)
    }

    @Test("A cell height of zero cannot divide, and reports nothing rather than crashing")
    func degenerateCellHeight() {
        var accumulator = ScrollAccumulator()
        #expect(accumulator.consume(translation: 100, cellHeight: 0) == 0)
    }

    /// A pointer begins a drag lift on click-and-drag with no long press, and the lift
    /// fails every competing recogniser — including the pan that selects text. An
    /// always-enabled drag interaction therefore meant a mouse could never select
    /// anything, so it exists only while there is a selection to drag.
    @Test @MainActor func dragInteractionFollowsTheSelection() {
        let view = TerminalInputView()
        let drag = view.interactions.compactMap { $0 as? UIDragInteraction }.first
        #expect(drag != nil, "the terminal takes part in drag and drop")
        #expect(drag?.isEnabled == false, "nothing is selected, so nothing is draggable")

        view.setSelection(TerminalRange(start: TerminalPosition(row: 0, column: 0), end: TerminalPosition(row: 0, column: 4)))
        #expect(drag?.isEnabled == true, "a selection can be dragged")

        view.clearSelection()
        #expect(drag?.isEnabled == false, "and the pointer can select again once it is gone")
    }
}
