import Foundation
import Testing
import UIKit
@testable import ApexTerminal

/// Input-method composition in the terminal (D-039).
///
/// The buffer is tested on its own, and then the view is driven through the actual
/// `UITextInput` calls an input method makes — `setMarkedText` while the syllables are
/// still being chosen, `insertText` when one is committed. Testing `insertText` alone
/// proves nothing about Pinyin: that is the one call that already worked.
@Suite struct TerminalCompositionTests {
    // MARK: - The buffer

    @Test("Editing works in characters, not in UTF-16 units or bytes")
    func graphemeClusters() {
        var composition = TerminalComposition()
        // A Hangul syllable, an emoji with a skin tone, and a letter with a combining
        // mark are each one character to a person and several to UTF-16.
        composition.replace(0 ..< 0, with: "한👍🏽é")
        #expect(composition.count == 3, "three characters, whatever their storage costs")

        let removedOne = composition.deleteBackward()
        #expect(removedOne)
        #expect(composition.text == "한👍🏽", "backspace removes a whole cluster, not half an emoji")
        let removedTwo = composition.deleteBackward()
        #expect(removedTwo)
        #expect(composition.text == "한")
    }

    @Test("The caret follows what was typed, and a selection is replaced by it")
    func selection() {
        var composition = TerminalComposition()
        composition.replace(0 ..< 0, with: "nihao")
        #expect(composition.selected == 5 ..< 5, "the caret sits after the insertion")

        composition.select(0 ..< 2)
        composition.replace(composition.selected, with: "N")
        #expect(composition.text == "Nhao")
        #expect(composition.selected == 1 ..< 1)
    }

    @Test("An input method's selection is relative to the text it just set")
    func markedSelectionIsRelative() {
        var composition = TerminalComposition()
        composition.setMarked("nihao", selectedRange: 2 ..< 2, replacing: 0 ..< 0)
        #expect(composition.text == "nihao")
        #expect(composition.selected == 2 ..< 2)

        // Replacing the whole marked run, as an input method does on every keystroke.
        composition.setMarked("nihaoma", selectedRange: 7 ..< 7, replacing: 0 ..< 5)
        #expect(composition.text == "nihaoma")
        #expect(composition.selected == 7 ..< 7)
    }

    @Test("A stale position from the system cannot index past the buffer")
    func clamping() {
        var composition = TerminalComposition()
        composition.replace(0 ..< 0, with: "ab")
        #expect(composition.clamped(99) == 2)
        #expect(composition.clamped(-5) == 0)
        #expect(composition.substring(0 ..< 99) == "ab", "an over-long range is clamped, not a crash")
        // A range starting past the end collapses to empty rather than reading off it.
        // (`5 ..< 3` cannot be written at all: Swift traps building it.)
        #expect(composition.clamped(5 ..< 7).isEmpty)
        #expect(composition.substring(5 ..< 7) == "")
    }

    @Test("Backspace on an empty buffer belongs to the shell")
    func emptyBackspaceIsNotOurs() {
        var composition = TerminalComposition()
        let deleted = composition.deleteBackward()
        #expect(!deleted, "nothing composed, so the key is the shell's")
    }

    // MARK: - The view, driven the way an input method drives it

    @MainActor
    private func inputView() -> (TerminalInputView, () -> [UInt8]) {
        let view = TerminalInputView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let sent = Box()
        view.onInput = { data in sent.bytes.append(contentsOf: data) }
        return (view, { sent.bytes })
    }

    private final class Box { var bytes: [UInt8] = [] }

    @Test("Composing Pinyin sends nothing until the input method commits")
    @MainActor func pinyinSendsOnlyTheCommittedText() {
        let (view, sent) = inputView()

        // What the input method does as the user types n-i-h-a-o: it sets marked text,
        // replacing what it set before, and sends nothing to the document.
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        view.setMarkedText("niha", selectedRange: NSRange(location: 4, length: 0))
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        #expect(sent().isEmpty, "five Latin letters must not reach the shell")
        #expect(view.markedTextRange != nil, "and the text is marked, so the candidate list shows")

        // Choosing a candidate: the input method commits through insertText.
        view.insertText("你好")
        #expect(String(decoding: sent(), as: UTF8.self) == "你好", "exactly the committed characters, once")
        #expect(view.markedTextRange == nil, "and nothing is left marked")
    }

    @Test("Cancelling a composition sends nothing at all")
    @MainActor func cancelledCompositionSendsNothing() {
        let (view, sent) = inputView()
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        // Backspacing the composition away is how a person cancels it.
        for _ in 0 ..< 5 { view.deleteBackward() }
        #expect(sent().isEmpty, "neither the syllables nor a DEL reaches the shell")
        #expect(view.markedTextRange == nil)

        // And once the buffer is empty, backspace is the shell's again.
        view.deleteBackward()
        #expect(sent() == [0x7F], "DEL, which is what OpenSSH negotiates for erase")
    }

    @Test("A composition left marked is committed before anything typed after it")
    @MainActor func strayCompositionCannotOvertakeLaterInput() {
        let (view, sent) = inputView()
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        // A hardware keystroke arriving while the buffer is marked must not send "ni"
        // after the character that replaced it.
        view.insertText("x")
        #expect(String(decoding: sent(), as: UTF8.self) == "x", "the abandoned syllables are dropped, not appended")
    }

    @Test("Return still means carriage return, and English still goes straight through")
    @MainActor func plainTypingIsUnchanged() {
        let (view, sent) = inputView()
        view.insertText("ls")
        view.insertText("\n")
        #expect(sent() == Array("ls\r".utf8), "no composition, no change in behaviour")
    }

    @Test("The document an input method sees is the composition and nothing else")
    @MainActor func documentIsOnlyTheComposition() {
        let (view, _) = inputView()
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        let whole = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument)
        #expect(view.text(in: whole!) == "nihao")
        // The shell's output is not addressable: it is not here, it is on the far end.
        #expect(view.offset(from: view.beginningOfDocument, to: view.endOfDocument) == 5)
    }
}
