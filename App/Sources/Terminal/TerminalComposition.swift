import Foundation

/// The text an input method is still assembling (D-039).
///
/// A terminal has no local document: the shell owns every character, and what is on screen
/// arrived from the far end. `UITextInput` is written for an editable document, so the
/// document this view exposes is *only* the composition — the Pinyin, kana or Hangul an
/// input method has not committed yet. Everything already sent is not editable, because it
/// is not here.
///
/// Offsets are in Characters, not UTF-16 units and not bytes. An input method edits what a
/// person sees as one character, and a grapheme cluster — a Hangul syllable, an emoji with
/// a skin tone, a base letter with a combining mark — is one of those and several of
/// everything else.
struct TerminalComposition: Equatable {
    private(set) var text: String = ""
    /// Where the caret or selection sits inside `text`, in Character offsets.
    private(set) var selected: Range<Int> = 0 ..< 0

    var isEmpty: Bool { text.isEmpty }
    var count: Int { text.count }

    /// Clamps an offset to the composition, so a stale position from the system cannot
    /// index past the end of a buffer that has since been committed or shortened.
    func clamped(_ offset: Int) -> Int { min(max(0, offset), count) }

    func clamped(_ range: Range<Int>) -> Range<Int> {
        let lower = clamped(range.lowerBound)
        return lower ..< clamped(max(range.upperBound, lower))
    }

    func substring(_ range: Range<Int>) -> String {
        let range = clamped(range)
        let characters = Array(text)
        return String(characters[range])
    }

    /// Replaces a range and puts the caret after what was written — what typing does.
    mutating func replace(_ range: Range<Int>, with replacement: String) {
        let range = clamped(range)
        var characters = Array(text)
        characters.replaceSubrange(range, with: Array(replacement))
        text = String(characters)
        let caret = range.lowerBound + replacement.count
        selected = caret ..< caret
    }

    /// Replaces the marked region and places the selection the input method asked for,
    /// which it expresses relative to the text it just set.
    mutating func setMarked(_ replacement: String, selectedRange: Range<Int>, replacing range: Range<Int>) {
        replace(range, with: replacement)
        let base = clamped(range).lowerBound
        let lower = clamped(base + selectedRange.lowerBound)
        let upper = clamped(base + selectedRange.upperBound)
        selected = lower ..< max(lower, upper)
    }

    mutating func select(_ range: Range<Int>) { selected = clamped(range) }

    /// Deletes the selection, or the character before the caret when there is none.
    /// Returns false when there was nothing to delete, so the caller knows the keystroke
    /// belongs to the shell instead.
    mutating func deleteBackward() -> Bool {
        if !selected.isEmpty {
            replace(selected, with: "")
            return true
        }
        guard selected.lowerBound > 0 else { return false }
        replace(selected.lowerBound - 1 ..< selected.lowerBound, with: "")
        return true
    }

    /// Takes the whole composition and empties it — what happens when an input method
    /// commits, or when the session has to be told about it.
    mutating func take() -> String {
        defer { self = TerminalComposition() }
        return text
    }
}
