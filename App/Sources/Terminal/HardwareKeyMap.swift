import Foundation
import UIKit

/// Maps a hardware key press to the bytes a terminal expects, the way xterm does.
///
/// Pure so it can be tested without a `UIKey`, which has no public initialiser. The rules:
/// Command never reaches the remote host; Control produces the control byte for character
/// keys; Option is Meta (an `ESC` prefix) for characters; arrows, Home/End, Insert/Delete,
/// Page keys and function keys carry their modifiers in the xterm parameter form
/// (`CSI 1;5C` for Control-Right), which is what shells and editors use for word movement
/// and selection; plain printable characters return `nil` because `insertText` delivers
/// them and sending them here too would double every keystroke.
enum HardwareKeyMap {
    static func encode(
        keyCode: UIKeyboardHIDUsage,
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers: UIKeyModifierFlags,
        applicationCursorKeys: Bool
    ) -> Data? {
        if modifiers.contains(.command) { return nil }
        let shift = modifiers.contains(.shift)
        let alt = modifiers.contains(.alternate)
        let control = modifiers.contains(.control)
        // xterm: 1 + shift(1) + alt(2) + control(4); 1 means "no modifier" and is omitted.
        let parameter = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (control ? 4 : 0)

        func cursor(_ letter: String) -> Data {
            if parameter > 1 { return Data("\u{1B}[1;\(parameter)\(letter)".utf8) }
            return Data((applicationCursorKeys ? "\u{1B}O\(letter)" : "\u{1B}[\(letter)").utf8)
        }
        func tilde(_ number: Int) -> Data {
            parameter > 1 ? Data("\u{1B}[\(number);\(parameter)~".utf8) : Data("\u{1B}[\(number)~".utf8)
        }
        func pf(_ letter: String) -> Data {
            parameter > 1 ? Data("\u{1B}[1;\(parameter)\(letter)".utf8) : Data("\u{1B}O\(letter)".utf8)
        }

        switch keyCode {
        case .keyboardUpArrow: return cursor("A")
        case .keyboardDownArrow: return cursor("B")
        case .keyboardRightArrow: return cursor("C")
        case .keyboardLeftArrow: return cursor("D")
        case .keyboardHome: return cursor("H")
        case .keyboardEnd: return cursor("F")
        case .keyboardInsert: return tilde(2)
        case .keyboardDeleteForward: return tilde(3)
        case .keyboardPageUp: return tilde(5)
        case .keyboardPageDown: return tilde(6)
        case .keyboardF1: return pf("P")
        case .keyboardF2: return pf("Q")
        case .keyboardF3: return pf("R")
        case .keyboardF4: return pf("S")
        case .keyboardF5: return tilde(15)
        case .keyboardF6: return tilde(17)
        case .keyboardF7: return tilde(18)
        case .keyboardF8: return tilde(19)
        case .keyboardF9: return tilde(20)
        case .keyboardF10: return tilde(21)
        case .keyboardF11: return tilde(23)
        case .keyboardF12: return tilde(24)
        case .keyboardDeleteOrBackspace:
            // Control-Backspace is BS in most terminals; Option-Backspace deletes a word
            // in readline, as Meta-DEL.
            if control { return Data([0x08]) }
            return alt ? Data([0x1B, 0x7F]) : Data([0x7F])
        case .keyboardReturnOrEnter, .keypadEnter:
            return alt ? Data([0x1B, 0x0D]) : Data([0x0D])
        case .keyboardTab:
            return shift ? Data("\u{1B}[Z".utf8) : Data([0x09])
        case .keyboardEscape:
            return Data([0x1B])
        default:
            break
        }

        if control, let scalar = charactersIgnoringModifiers.unicodeScalars.first,
           let byte = controlByte(for: scalar) {
            return Data([byte])
        }
        guard !characters.isEmpty else { return nil }
        if alt {
            // Option is Meta: `ESC` followed by the character, which is what readline and
            // Emacs bindings expect.
            return Data([0x1B]) + Data(characters.utf8)
        }
        // Plain characters arrive through `insertText`; returning nil avoids sending them twice.
        return nil
    }

    static func controlByte(for scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "a" ... "z": UInt8(scalar.value - 0x60)
        case "A" ... "Z": UInt8(scalar.value - 0x40)
        case "@": 0x00
        case "[": 0x1B
        case "\\": 0x1C
        case "]": 0x1D
        case "^": 0x1E
        case "_": 0x1F
        case " ": 0x00
        case "?": 0x7F
        default: nil
        }
    }
}
