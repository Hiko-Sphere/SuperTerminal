import UIKit

/// `UITextInput` over the composition buffer, which is what makes Pinyin, kana and Hangul
/// work in the terminal (D-039).
///
/// `UIKeyInput` alone receives only committed characters. An input method needs somewhere
/// to put the syllables it is still assembling and somewhere to draw its candidate list,
/// and it asks for both through `UITextInput`. Without it, iOS either drops the
/// composition or commits every keystroke as a literal — so a Chinese user typing `nihao`
/// sends five Latin letters to the shell.
///
/// The document is the composition and nothing else. Positions outside it do not exist,
/// because the text they would refer to lives on the far end of an SSH connection.
extension TerminalInputView: UITextInput {
    // MARK: - Positions and ranges

    /// An offset into the composition, in Characters.
    final class Position: UITextPosition {
        let offset: Int
        init(_ offset: Int) { self.offset = offset }
        override var description: String { "Position(\(offset))" }
    }

    final class Range_: UITextRange {
        let range: Swift.Range<Int>
        init(_ range: Swift.Range<Int>) { self.range = range }
        override var start: UITextPosition { Position(range.lowerBound) }
        override var end: UITextPosition { Position(range.upperBound) }
        override var isEmpty: Bool { range.isEmpty }
    }

    private func offset(_ position: UITextPosition?) -> Int? {
        (position as? Position).map { composition.clamped($0.offset) }
    }

    private func swiftRange(_ range: UITextRange?) -> Swift.Range<Int>? {
        (range as? Range_).map { composition.clamped($0.range) }
    }

    // MARK: - The document

    var beginningOfDocument: UITextPosition { Position(0) }
    var endOfDocument: UITextPosition { Position(composition.count) }

    var selectedTextRange: UITextRange? {
        get { Range_(composition.selected) }
        set {
            guard let range = swiftRange(newValue) else { return }
            composition.select(range)
            refreshComposition()
        }
    }

    var markedTextRange: UITextRange? {
        // Everything in the buffer is marked: the moment an input method commits, the
        // text leaves for the shell and the buffer is empty again.
        composition.isEmpty ? nil : Range_(0 ..< composition.count)
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set { _ = newValue }
    }

    func text(in range: UITextRange) -> String? {
        swiftRange(range).map { composition.substring($0) }
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard let range = swiftRange(range) else { return }
        composition.replace(range, with: text)
        refreshComposition()
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        let replacing = composition.isEmpty ? 0 ..< 0 : 0 ..< composition.count
        let selected = selectedRange.location == NSNotFound
            ? (markedText?.count ?? 0) ..< (markedText?.count ?? 0)
            : selectedRange.location ..< (selectedRange.location + selectedRange.length)
        composition.setMarked(markedText ?? "", selectedRange: selected, replacing: replacing)
        refreshComposition()
    }

    func unmarkText() {
        // The input method has finished. Whatever is left is committed text, and committed
        // text belongs to the shell.
        commitComposition()
    }

    // MARK: - Geometry
    //
    // The candidate list positions itself against these, so getting them wrong puts the
    // suggestions over the text being typed rather than beside it.

    func caretRect(for position: UITextPosition) -> CGRect {
        let column = offset(position) ?? composition.selected.lowerBound
        return compositionCaretRect(atCharacterOffset: column)
    }

    func firstRect(for range: UITextRange) -> CGRect {
        guard let range = swiftRange(range) else { return .zero }
        let start = compositionCaretRect(atCharacterOffset: range.lowerBound)
        let end = compositionCaretRect(atCharacterOffset: range.upperBound)
        return CGRect(x: start.minX, y: start.minY, width: max(end.minX - start.minX, 1), height: start.height)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard let cell = compositionOriginAndCellWidth() else { return beginningOfDocument }
        let column = Int(((point.x - cell.origin.x) / cell.width).rounded())
        return Position(composition.clamped(column))
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let bounds = swiftRange(range), let position = closestPosition(to: point) as? Position
        else { return nil }
        return Position(min(max(position.offset, bounds.lowerBound), bounds.upperBound))
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        guard let position = closestPosition(to: point) as? Position, position.offset < composition.count
        else { return nil }
        return Range_(position.offset ..< position.offset + 1)
    }

    // MARK: - Position arithmetic

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let base = self.offset(position) else { return nil }
        let moved = base + offset
        guard moved >= 0, moved <= composition.count else { return nil }
        return Position(moved)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left, .up: self.position(from: position, offset: -offset)
        case .right, .down: self.position(from: position, offset: offset)
        @unknown default: nil
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = offset(position) ?? 0, b = offset(other) ?? 0
        return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        (offset(toPosition) ?? 0) - (offset(from) ?? 0)
    }

    func textRange(from: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let a = offset(from), let b = offset(toPosition) else { return nil }
        return Range_(min(a, b) ..< max(a, b))
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let range = swiftRange(range) else { return nil }
        switch direction {
        case .left, .up: return Position(range.lowerBound)
        case .right, .down: return Position(range.upperBound)
        @unknown default: return nil
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let base = offset(position) else { return nil }
        switch direction {
        case .left, .up: return Range_(composition.clamped(base - 1) ..< base)
        case .right, .down: return Range_(base ..< composition.clamped(base + 1))
        @unknown default: return nil
        }
    }

    // MARK: - Writing direction

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // MARK: - Required but not applicable

    var inputDelegate: UITextInputDelegate? {
        get { textInputDelegate }
        set { textInputDelegate = newValue }
    }

    var tokenizer: UITextInputTokenizer { compositionTokenizer }
}
