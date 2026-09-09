import Foundation
import Testing

@testable import ApexTerminal

/// The arithmetic behind split panes (D-055).
///
/// Layout is where this kind of feature goes wrong in ways nobody notices until they are
/// stuck: a pane that cannot be closed, a divider dragged until a pane has no width, a
/// focus pointing at something that is no longer on screen. All of that is cheap to check
/// here and expensive to find by hand, so the model is a value type and every operation is
/// tested rather than trusted.
@Suite("Split pane layout")
struct PaneLayoutTests {
    private let alpha = PaneLayout.Content.terminal(UUID())
    private let beta = PaneLayout.Content.terminal(UUID())
    private let screen = PaneLayout.Content.screen(UUID())

    @Test("An empty layout has nothing open and nothing focused")
    func emptyIsEmpty() {
        let layout = PaneLayout()
        #expect(layout.paneCount == 0)
        #expect(layout.focused == nil)
        #expect(layout.panes.isEmpty)
        #expect(layout.focusedContent == nil)
    }

    @Test("Splitting an empty layout just shows the thing")
    func splittingNothingShowsIt() {
        var layout = PaneLayout()
        layout.split(alpha, axis: .horizontal)
        #expect(layout.paneCount == 1)
        #expect(layout.focusedContent == alpha)
    }

    @Test("Splitting replaces the focused pane with two, and focuses the new one")
    func splittingFocusesTheNewPane() {
        var layout = PaneLayout(content: alpha)
        let newPane = layout.split(beta, axis: .horizontal)

        #expect(layout.paneCount == 2)
        #expect(layout.focused == newPane)
        #expect(layout.focusedContent == beta)
        // Order is what the eye reads and what focus cycling follows.
        #expect(layout.panes.map(\.content) == [alpha, beta])
    }

    @Test("A terminal and a screen can share the screen, which is the point")
    func terminalsAndScreensMix() {
        var layout = PaneLayout(content: alpha)
        layout.split(screen, axis: .horizontal)
        layout.split(beta, axis: .vertical)

        #expect(layout.paneCount == 3)
        #expect(Set(layout.panes.map(\.content)) == [alpha, screen, beta])
    }

    @Test("Closing a pane gives its space to its sibling and collapses the split")
    func closingCollapsesTheSplit() {
        var layout = PaneLayout(content: alpha)
        let second = layout.split(beta, axis: .horizontal)
        layout.close(second)

        #expect(layout.paneCount == 1)
        #expect(layout.panes.map(\.content) == [alpha])
        // Focus has to land somewhere real, or the keyboard goes nowhere.
        #expect(layout.focused == layout.panes.first?.id)
    }

    @Test("Closing the last pane empties the layout rather than leaving a husk")
    func closingTheLastPaneEmpties() {
        var layout = PaneLayout(content: alpha)
        layout.close(layout.panes[0].id)
        #expect(layout.paneCount == 0)
        #expect(layout.focused == nil)
    }

    @Test("Closing a deeply nested pane leaves the rest intact")
    func closingNestedKeepsTheRest() {
        var layout = PaneLayout(content: alpha)
        layout.split(beta, axis: .horizontal)
        let third = layout.split(screen, axis: .vertical)
        #expect(layout.paneCount == 3)

        layout.close(third)
        #expect(layout.paneCount == 2)
        #expect(layout.panes.map(\.content) == [alpha, beta])
    }

    @Test("Closing every pane one at a time never strands focus")
    func closingEverythingNeverStrandsFocus() {
        var layout = PaneLayout(content: alpha)
        layout.split(beta, axis: .horizontal)
        layout.split(screen, axis: .vertical)

        while layout.paneCount > 0 {
            // Whatever is focused must be a pane that exists — checked at every step,
            // because "focus points at a closed pane" is the bug that makes the keyboard
            // stop working with no visible cause.
            if let focused = layout.focused {
                #expect(layout.panes.contains { $0.id == focused }, "focus pointed at a pane that is gone")
            }
            layout.close(layout.panes[0].id)
        }
        #expect(layout.focused == nil)
    }

    @Test("A session that ends takes all of its panes with it")
    func endingASessionClosesEveryPaneShowingIt() {
        var layout = PaneLayout(content: alpha)
        layout.split(alpha, axis: .horizontal)
        layout.split(beta, axis: .vertical)
        #expect(layout.paneCount == 3)

        layout.closeAll(showing: alpha)
        #expect(layout.paneCount == 1)
        #expect(layout.panes.map(\.content) == [beta])
        #expect(layout.focused == layout.panes.first?.id)
    }

    @Test("Focus cycles in reading order and wraps in both directions")
    func focusCycles() {
        var layout = PaneLayout(content: alpha)
        layout.split(beta, axis: .horizontal)
        layout.split(screen, axis: .horizontal)
        let order = layout.panes.map(\.id)

        layout.focus(order[0])
        layout.focusNext()
        #expect(layout.focused == order[1])
        layout.focusNext()
        #expect(layout.focused == order[2])
        layout.focusNext()
        #expect(layout.focused == order[0], "focus should wrap")

        layout.focusNext(reverse: true)
        #expect(layout.focused == order[2], "and wrap backwards too")
    }

    @Test("Focusing a pane that is not there changes nothing")
    func focusingSomethingGoneIsIgnored() {
        var layout = PaneLayout(content: alpha)
        let real = layout.focused
        layout.focus(UUID())
        #expect(layout.focused == real)
    }

    @Test("A divider cannot be dragged until a pane disappears")
    func dividersAreClamped() {
        var layout = PaneLayout(content: alpha)
        layout.split(beta, axis: .horizontal)
        guard case let .split(splitID, _, _, _, _) = layout.root else {
            Issue.record("expected a split at the root")
            return
        }

        layout.resize(splitID, to: 0.0)
        guard case let .split(_, _, _, _, low) = layout.root else { return }
        #expect(low == PaneLayout.minimumFraction, "a pane squeezed to nothing cannot be closed or read")

        layout.resize(splitID, to: 1.0)
        guard case let .split(_, _, _, _, high) = layout.root else { return }
        #expect(high == 1 - PaneLayout.minimumFraction)

        layout.resize(splitID, to: 0.42)
        guard case let .split(_, _, _, _, middle) = layout.root else { return }
        #expect(middle == 0.42, "an ordinary drag is left alone")
    }

    @Test("Choosing a connection replaces the arrangement rather than adding to it")
    func showingReplaces() {
        var layout = PaneLayout(content: alpha)
        layout.split(beta, axis: .horizontal)
        layout.show(screen)

        // Tapping a connection is not the same gesture as splitting, and quietly adding a
        // fourth pane every time somebody taps the list would be its own kind of wrong.
        #expect(layout.paneCount == 1)
        #expect(layout.focusedContent == screen)
    }
}
