import Foundation
import Testing
import UIKit
@testable import SuperTerminal

/// The app side of remote screens (D-022): the record, the key table, the recognisers
/// and the point mapping. The protocol itself is proven against LibVNCServer in the
/// package; the screen over SSH end to end is a UI test against the same server.
@Suite("Remote screens")
struct VNCTests {
    @Test("Records without screen sharing still decode, and settings round-trip")
    func settingsCodable() throws {
        let host = Host(
            name: "Desk", hostname: "desk.example", username: "me", credentials: [.password],
            vnc: Host.VNCSettings(port: 5901, viaSSH: true, targetHost: "10.0.0.2", hasPassword: true)
        )
        let data = try JSONEncoder().encode(host)
        let back = try JSONDecoder().decode(Host.self, from: data)
        #expect(back.vnc == host.vnc)
        #expect(back == host)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "vnc")
        let older = try JSONDecoder().decode(Host.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.vnc == nil, "a record written before screen sharing existed decodes with none")

        var bad = host
        bad.vnc?.port = 70000
        #expect(bad.validationProblems.contains { $0.contains("port") })
        #expect(host.validationProblems.isEmpty)
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
