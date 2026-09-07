import Foundation
import Testing
import UIKit
@testable import ApexTerminal

/// The hardware-key mapping, as xterm defines it. Pure, so every rule is a one-line case.
@Suite struct HardwareKeyMapTests {
    private func bytes(_ code: UIKeyboardHIDUsage, mods: UIKeyModifierFlags = [], chars: String = "",
                       ignoring: String? = nil, app: Bool = false) -> [UInt8]? {
        HardwareKeyMap.encode(keyCode: code, characters: chars, charactersIgnoringModifiers: ignoring ?? chars,
                              modifiers: mods, applicationCursorKeys: app).map { Array($0) }
    }
    private func str(_ code: UIKeyboardHIDUsage, mods: UIKeyModifierFlags = [], chars: String = "",
                     ignoring: String? = nil, app: Bool = false) -> String? {
        bytes(code, mods: mods, chars: chars, ignoring: ignoring, app: app).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func arrowsFollowCursorMode() {
        #expect(str(.keyboardUpArrow) == "\u{1B}[A")
        #expect(str(.keyboardUpArrow, app: true) == "\u{1B}OA")
        #expect(str(.keyboardEnd, app: true) == "\u{1B}OF")
    }

    @Test func modifiedArrowsUseTheXtermParameter() {
        #expect(str(.keyboardRightArrow, mods: [.control]) == "\u{1B}[1;5C", "Control-Right moves a word")
        #expect(str(.keyboardUpArrow, mods: [.shift]) == "\u{1B}[1;2A", "Shift-Up extends a selection in editors")
        #expect(str(.keyboardLeftArrow, mods: [.alternate]) == "\u{1B}[1;3D")
        #expect(str(.keyboardEnd, mods: [.control, .shift]) == "\u{1B}[1;6F")
        // The modifier form wins even in application cursor mode.
        #expect(str(.keyboardDownArrow, mods: [.control], app: true) == "\u{1B}[1;5B")
    }

    @Test func tildeKeysCarryModifiers() {
        #expect(str(.keyboardPageUp) == "\u{1B}[5~")
        #expect(str(.keyboardPageDown, mods: [.shift]) == "\u{1B}[6;2~")
        #expect(str(.keyboardInsert) == "\u{1B}[2~")
        #expect(str(.keyboardDeleteForward, mods: [.control]) == "\u{1B}[3;5~")
    }

    @Test func functionKeys() {
        #expect(str(.keyboardF1) == "\u{1B}OP")
        #expect(str(.keyboardF1, mods: [.shift]) == "\u{1B}[1;2P")
        #expect(str(.keyboardF5) == "\u{1B}[15~")
        #expect(str(.keyboardF5, mods: [.control]) == "\u{1B}[15;5~")
        #expect(str(.keyboardF12) == "\u{1B}[24~")
    }

    @Test func controlCharacters() {
        #expect(bytes(.keyboardC, mods: [.control], chars: "\u{03}", ignoring: "c") == [0x03])
        #expect(bytes(.keyboardSpacebar, mods: [.control], chars: " ") == [0x00])
        #expect(bytes(.keyboardOpenBracket, mods: [.control], chars: "[") == [0x1B])
        #expect(bytes(.keyboardDeleteOrBackspace, mods: [.control]) == [0x08], "Control-Backspace is BS")
    }

    @Test func optionIsMeta() {
        #expect(bytes(.keyboardX, mods: [.alternate], chars: "x") == [0x1B, 0x78])
        #expect(bytes(.keyboardDeleteOrBackspace, mods: [.alternate]) == [0x1B, 0x7F], "Meta-DEL deletes a word")
        #expect(bytes(.keyboardReturnOrEnter, mods: [.alternate], chars: "\r") == [0x1B, 0x0D])
    }

    @Test func editingKeys() {
        #expect(bytes(.keyboardTab, chars: "\t") == [0x09])
        #expect(str(.keyboardTab, mods: [.shift], chars: "\t") == "\u{1B}[Z")
        #expect(bytes(.keyboardEscape) == [0x1B])
        #expect(bytes(.keyboardDeleteOrBackspace) == [0x7F])
        #expect(bytes(.keypadEnter, chars: "\r") == [0x0D])
    }

    @Test func commandNeverReachesTheHostAndPlainCharactersComeThroughInsertText() {
        #expect(bytes(.keyboardK, mods: [.command], chars: "k") == nil)
        #expect(bytes(.keyboardUpArrow, mods: [.command]) == nil)
        #expect(bytes(.keyboardA, chars: "a") == nil)
        #expect(bytes(.keyboardA, mods: [.shift], chars: "A", ignoring: "a") == nil)
    }
}
