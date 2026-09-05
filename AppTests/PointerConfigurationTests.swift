import Foundation
import Testing
import UIKit
@testable import SuperTerminal

/// Pointer support is UIKit configuration that XCUITest cannot drive on iOS, so the
/// configuration itself is asserted: the recognisers exist with the masks that make a
/// scroll wheel, a secondary click, a middle click and a click-drag reach the view.
@Suite struct PointerConfigurationTests {
    @Test @MainActor func scrollWheelRecogniserTakesScrollEventsAndNoTouches() {
        let view = TerminalInputView()
        let pans = view.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer } ?? []
        let wheel = pans.first { $0.allowedScrollTypesMask == .all }
        #expect(wheel != nil, "a pan recogniser must accept pointer scroll events")
        #expect(wheel?.allowedTouchTypes.isEmpty == true, "it must not compete for touches")
    }

    @Test @MainActor func clickDragIsIndirectPointerOnly() {
        let view = TerminalInputView()
        let pans = view.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer } ?? []
        let drag = pans.first { $0.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)] }
        #expect(drag != nil, "a one-touch indirect-pointer pan selects text with a mouse")
        #expect(drag?.maximumNumberOfTouches == 1)
    }

    @Test @MainActor func secondaryAndMiddleClicksAreRecognised() {
        let view = TerminalInputView()
        let taps = view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        #expect(taps.contains { $0.buttonMaskRequired == .secondary })
        #expect(taps.contains { $0.buttonMaskRequired == .button(3) })
    }

    /// A button mask is not a pointer check. Without the touch-type restriction a
    /// synthesised direct tap satisfied the middle-click recogniser and pasted the
    /// pasteboard into the shell — measured in the live-terminal UI tests, where every
    /// tap on the terminal ran the previous test's copied prompt as a command.
    @Test @MainActor func clickRecognisersTakePointerTouchesOnly() {
        let view = TerminalInputView()
        let pointerOnly = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let clicks = (view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? [])
            .filter { $0.buttonMaskRequired == .secondary || $0.buttonMaskRequired == .button(3) }
        #expect(clicks.count == 2)
        for click in clicks {
            #expect(click.allowedTouchTypes == pointerOnly, "a finger must never be a secondary or middle click")
        }
    }

    @Test @MainActor func editMenuAndPointerStyleAreInstalled() {
        let view = TerminalInputView()
        #expect(view.interactions.contains { $0 is UIEditMenuInteraction })
        #expect(view.interactions.contains { $0 is UIPointerInteraction })
    }

    @Test @MainActor func standardEditActionsFollowState() {
        let view = TerminalInputView()
        #expect(!view.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil), "nothing selected yet")
        UIPasteboard.general.string = "paste-me"
        #expect(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        UIPasteboard.general.string = ""
    }
}
