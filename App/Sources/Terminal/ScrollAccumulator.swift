import CoreGraphics

/// Turns pointer and touch movement into whole rows of scrolling (D-025).
///
/// It is a value type with no UIKit in it because the bug it fixes is arithmetic, not
/// gestures: a mouse wheel delivers one notch as an entire gesture — `.began` and then
/// `.ended`, with no `.changed` — and a notch is usually shorter than one line of text.
/// A handler that read the movement only while a gesture was *changing*, and threw away
/// what it had whenever one began, could therefore never reach a whole row: the wheel did
/// nothing at all while a trackpad, which sends a continuous stream, worked. So movement
/// is accumulated wherever it arrives and kept between gestures until it amounts to a row.
struct ScrollAccumulator {
    private var pending: CGFloat = 0

    /// Adds `translation` and returns the whole rows it now amounts to, keeping the
    /// remainder. Positive is downward movement, which scrolls back through history.
    mutating func consume(translation: CGFloat, cellHeight: CGFloat) -> Int {
        guard cellHeight > 0 else { return 0 }
        pending += translation
        let rows = Int(pending / cellHeight)
        guard rows != 0 else { return 0 }
        pending -= CGFloat(rows) * cellHeight
        return rows
    }

    /// Forgets the remainder. A cancelled gesture did not mean to scroll.
    mutating func reset() { pending = 0 }
}
