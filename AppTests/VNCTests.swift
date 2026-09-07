import Foundation
import Testing
import UIKit
@testable import ApexTerminal

/// The app side of remote screens (D-022): the record, the key table, the recognisers
/// and the point mapping. The protocol itself is proven against LibVNCServer in the
/// package; the screen over SSH end to end is a UI test against the same server.
@Suite("Remote screens")
struct VNCTests {
    /// Screens are their own connections now (D-027), so the only job left for the old
    /// field is to decode: a record written before the split, or one arriving from a
    /// device still on the old version, must be readable so it can be migrated. What it
    /// then becomes is `ScreenConnectionTests`.
    @Test("A connection record written before the split still decodes, with and without its screen")
    func legacyScreenSettingsStillDecode() throws {
        let json = """
        {
          "id": "00000000-0000-4000-A000-0000000000FF",
          "name": "Desk",
          "hostname": "desk.example",
          "port": 22,
          "username": "me",
          "transport": { "directTCP": {} },
          "credentials": [{ "password": {} }],
          "tags": [],
          "terminalType": "xterm-256color",
          "environment": {},
          "vnc": { "port": 5901, "viaSSH": true, "targetHost": "10.0.0.2", "hasPassword": true }
        }
        """
        let host = try JSONDecoder().decode(Host.self, from: Data(json.utf8))
        #expect(host.vnc?.port == 5901)
        #expect(host.vnc?.viaSSH == true)
        #expect(host.vnc?.targetHost == "10.0.0.2")
        #expect(host.vnc?.hasPassword == true)
        // The screen no longer takes part in the connection's own validity.
        #expect(host.validationProblems.isEmpty)

        var object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        object.removeValue(forKey: "vnc")
        let without = try JSONDecoder().decode(Host.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(without.vnc == nil, "a record that never had a screen decodes with none")
    }

    @Test("Hardware keys become keysyms; ⌘ stays with the app unless asked for")
    func keyMap() {
        func sym(_ code: UIKeyboardHIDUsage, _ chars: String, _ raw: String, _ mods: UIKeyModifierFlags = [], command: Bool = false) -> UInt32? {
            VNCKeyMap.keysym(keyCode: code, characters: chars, charactersIgnoringModifiers: raw, modifiers: mods, sendsCommandKey: command)
        }
        #expect(sym(.keyboardA, "a", "a") == 0x61)
        #expect(sym(.keyboardA, "A", "a", [.shift]) == 0x41, "a shifted letter is its own keysym")
        #expect(sym(.keyboardC, "\u{03}", "c", [.control]) == 0x63, "with Control the key underneath is sent; the modifier went separately")
        #expect(sym(.keyboardK, "k", "k", [.command]) == nil, "⌘K is the app's")
        #expect(sym(.keyboardK, "k", "k", [.command], command: true) == 0x6B, "unless ⌘ is being sent to the remote")
        #expect(sym(.keyboardLeftGUI, "", "") == nil)
        #expect(sym(.keyboardLeftGUI, "", "", command: true) == 0xFFEB, "then ⌘ itself is Super")
        #expect(sym(.keyboardLeftShift, "", "") == 0xFFE1)
        #expect(sym(.keyboardEscape, "\u{1B}", "\u{1B}") == 0xFF1B)
        #expect(sym(.keyboardReturnOrEnter, "\r", "\r") == 0xFF0D)
        #expect(sym(.keyboardDeleteOrBackspace, "\u{08}", "\u{08}") == 0xFF08)
        #expect(sym(.keyboardUpArrow, "", "") == 0xFF52)
        #expect(sym(.keyboardF5, "", "") == 0xFFC2)
        #expect(sym(.keyboardSpacebar, " ", " ") == 0x20)
        #expect(sym(.keyboardE, "é", "e", [.alternate]) == 0x65, "Option produces a composed character; the key underneath goes")
        #expect(sym(.keyboard0, "é", "é") == 0xE9, "a Latin-1 character typed directly is its own keysym")
        #expect(sym(.keyboard0, "中", "中") == 0x0100_4E2D, "beyond Latin-1 the Unicode keysym range is used")
        #expect(sym(.keyboardVolumeUp, "", "") == nil, "keys with no character and no name fall through")
    }

    /// The screen holds the keyboard whenever it is showing, so an external keyboard
    /// reaches the remote without anything being tapped first; the on-screen keyboard is
    /// a separate choice, kept down by a zero-height input view (D-029).
    @Test @MainActor func hardwareKeyboardDoesNotDependOnTheOnScreenOne() {
        let view = VNCScreenUIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(view.canBecomeFirstResponder, "it has to be in the responder chain to see key presses")
        #expect(view.showsSoftwareKeyboard == false, "the on-screen keyboard starts down")
        #expect(view.inputView != nil, "and is held down by an input view of no height, not by resigning")
        #expect(view.inputView?.frame.height == 0)

        view.showsSoftwareKeyboard = true
        #expect(view.inputView == nil, "asked for, the system keyboard comes up")
    }

    /// Same defect as the terminal's (D-025), in the other view: a wheel notch is a whole
    /// gesture, and shorter than one step.
    @Test @MainActor func wheelStepsSurviveBetweenGestures() {
        let view = VNCScreenUIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.update(framebufferSize: CGSize(width: 400, height: 300), desktopName: "desk")
        var steps: [(Int, Int)] = []
        view.onWheel = { _, _, vertical, horizontal in steps.append((vertical, horizontal)) }

        // Two notches of ten points each: neither reaches a step of 24 on its own.
        view.reportWheelForTesting(translation: CGPoint(x: 0, y: 10), at: CGPoint(x: 100, y: 100))
        #expect(steps.isEmpty)
        view.reportWheelForTesting(translation: CGPoint(x: 0, y: 10), at: CGPoint(x: 100, y: 100))
        #expect(steps.isEmpty)
        view.reportWheelForTesting(translation: CGPoint(x: 0, y: 10), at: CGPoint(x: 100, y: 100))
        #expect(steps.count == 1, "thirty points of movement is one step, however it arrived")
        #expect(steps.first?.0 == -1, "fingers moving down scrolls the wheel up")
    }

    @Test("Touch and pointer recognisers are set up as the design says")
    @MainActor func recognisers() {
        let view = VNCScreenUIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let recognisers = view.contentView.gestureRecognizers ?? []
        let pointerOnly = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let taps = recognisers.compactMap { $0 as? UITapGestureRecognizer }
        #expect(taps.contains { $0.numberOfTouchesRequired == 2 }, "two fingers tapped is the right click")
        let secondary = taps.filter { $0.buttonMaskRequired == .secondary }
        let middle = taps.filter { $0.buttonMaskRequired == .button(3) }
        #expect(secondary.count == 1 && secondary.allSatisfy { $0.allowedTouchTypes == pointerOnly },
                "click recognisers take pointer touches only (D-018)")
        #expect(middle.count == 1 && middle.allSatisfy { $0.allowedTouchTypes == pointerOnly })
        let pans = recognisers.compactMap { $0 as? UIPanGestureRecognizer }
        #expect(pans.contains { $0.allowedTouchTypes.isEmpty && $0.allowedScrollTypesMask == .all },
                "the wheel recogniser takes scroll events and no touches")
        #expect(pans.contains { $0.minimumNumberOfTouches == 2 && $0.maximumNumberOfTouches == 2 }, "two fingers moved is the wheel")
        #expect(pans.contains { $0.allowedTouchTypes == pointerOnly && $0.maximumNumberOfTouches == 1 }, "a pointer drag holds the button")
        #expect(recognisers.contains { $0 is UIHoverGestureRecognizer }, "a hovering pointer moves the remote one")
        #expect(recognisers.contains { ($0 as? UILongPressGestureRecognizer)?.minimumPressDuration == 0.4 }, "touch and hold drags")
        #expect(view.canBecomeFirstResponder, "the on-screen keyboard types into it")
        #expect(view.accessibilityIdentifier == "vnc-screen")
    }

    @Test("Points map onto the framebuffer through the letterboxed image, clamped at the edges")
    @MainActor func pointMapping() {
        let view = VNCScreenUIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.update(framebufferSize: CGSize(width: 800, height: 400), desktopName: "desk")
        // 800×400 into 400×300 fits at half size: 400×200, letterboxed 50 points top and bottom.
        #expect(view.imageRect() == CGRect(x: 0, y: 50, width: 400, height: 200))
        #expect(view.framebufferPoint(for: CGPoint(x: 200, y: 150)).map { [$0.x, $0.y] } == [400, 200])
        #expect(view.framebufferPoint(for: CGPoint(x: 0, y: 0)).map { [$0.x, $0.y] } == [0, 0], "above the image clamps to the top row")
        #expect(view.framebufferPoint(for: CGPoint(x: 399.5, y: 249.5)).map { [$0.x, $0.y] } == [799, 399])
        #expect(view.accessibilityValue == "desk, 800 × 400")
        view.update(framebufferSize: .zero, desktopName: "")
        #expect(view.framebufferPoint(for: CGPoint(x: 1, y: 1)) == nil, "nothing to click on before the server has said its size")
    }

    @Test("Latched modifiers are sent in a fixed order around the next key")
    func modifierOrder() {
        let all: VNCSession.Modifiers = [.superKey, .shift, .alt, .control]
        #expect(all.keysyms == [0xFFE1, 0xFFE3, 0xFFE9, 0xFFEB], "Shift, Control, Alt, Super — however they were latched")
        #expect(VNCSession.Modifiers().keysyms.isEmpty)
    }
}
