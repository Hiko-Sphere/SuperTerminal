import Foundation

/// How many terminal cells a grapheme cluster occupies.
///
/// This is the single most consequential piece of a terminal emulator that most get
/// subtly wrong. A remote program lays out its own output assuming a particular width
/// for every character; if the client disagrees by even one cell, `vim` draws over its
/// own status line, `tmux` panes tear, and CJK or emoji text corrupts the display. So
/// the policy has to match `wcwidth(3)`, not what looks best.
public enum CharacterWidth {
    /// Width of a single scalar, following the generated Unicode tables.
    ///
    /// Named distinctly from ``of(_:)-(Character)`` rather than overloaded: a literal
    /// like `"A"` can be either type, and an overload set would silently resolve one way
    /// at some call sites and the other way elsewhere.
    public static func ofScalar(_ scalar: Unicode.Scalar) -> Int {
        let value = scalar.value

        // C0 and C1 controls never reach the screen as glyphs.
        if value < 0x20 || (value >= 0x7F && value < 0xA0) { return 0 }

        if contains(zeroWidthMarkRanges, value) { return 0 }

        // Zero-width joiner, zero-width space and the bidi controls occupy no cells.
        if value == 0x200B || value == 0x200C || value == 0x200D { return 0 }
        if (0x202A ... 0x202E).contains(value) || (0x2060 ... 0x2064).contains(value) { return 0 }
        // Variation selectors modify the preceding character rather than adding a cell.
        if (0xFE00 ... 0xFE0F).contains(value) || (0xE0100 ... 0xE01EF).contains(value) { return 0 }

        if contains(eastAsianWideRanges, value) { return 2 }
        return 1
    }

    /// Width of a whole grapheme cluster — what actually lands in a cell.
    ///
    /// A cluster is not the sum of its parts. `é` spelled as `e` + U+0301 is one cell,
    /// not two; a family emoji joined by U+200D is two cells, not eight; a flag built
    /// from two regional indicators is two, not one each. So the rule is:
    ///
    /// * anything the Unicode data marks as emoji-by-default, or that carries the emoji
    ///   variation selector, or that is a joined or flag sequence, is **two** cells —
    ///   this is the convention terminals and fonts have settled on;
    /// * otherwise the cluster is as wide as its widest scalar, which for a base plus
    ///   combining marks is the base.
    public static func of(_ character: Character) -> Int {
        let scalars = Array(character.unicodeScalars)
        guard let base = scalars.first else { return 1 }

        // A flag is a pair of regional indicators rendered as one wide glyph.
        if (0x1F1E6 ... 0x1F1FF).contains(base.value) { return 2 }
        // A joined sequence renders as a single emoji regardless of how many components
        // it has.
        if scalars.contains(where: { $0.value == 0x200D }) { return 2 }
        // U+FE0F asks for emoji presentation, which is wide even when the base scalar is
        // a narrow text-presentation symbol — `❤️` and `⌚️` being the everyday cases.
        if scalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        // U+FE0E asks for text presentation, which stays narrow.
        if scalars.contains(where: { $0.value == 0xFE0E }) { return 1 }
        if base.properties.isEmojiPresentation { return 2 }

        var width = 0
        for scalar in scalars {
            width = max(width, ofScalar(scalar))
        }
        return max(width, 1)
    }

    /// Binary search over the sorted, merged range tables.
    static func contains(_ ranges: [ClosedRange<UInt32>], _ value: UInt32) -> Bool {
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = ranges[middle]
            if value < range.lowerBound {
                high = middle - 1
            } else if value > range.upperBound {
                low = middle + 1
            } else {
                return true
            }
        }
        return false
    }
}
