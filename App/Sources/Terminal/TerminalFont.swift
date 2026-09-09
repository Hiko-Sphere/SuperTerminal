import UIKit

/// Which font the terminal draws with (D-063).
///
/// A terminal is one font for hours a day, and the system's monospaced face is not everyone's.
/// What this adds is a *choice* — from the faces already on the device — with the one property
/// a terminal cannot do without: every glyph the same width. A proportional font in a grid
/// draws a screen that does not line up, so the picker offers only faces that measure the same
/// for a narrow character and a wide one.
enum TerminalFont {
    /// The name stored when the person has not chosen one.
    static let systemFamily = ""

    /// The faces for a family, falling back to the system's monospaced font.
    ///
    /// Falls back rather than fails: a font can be uninstalled, a backup can be restored onto
    /// a device that never had it, and a terminal that refused to draw would be the worst
    /// possible answer to "that font is gone".
    static func faces(family: String, size: CGFloat) -> (regular: UIFont, bold: UIFont) {
        guard !family.isEmpty,
              let regular = UIFont(name: family, size: size) ?? namedFont(inFamily: family, size: size)
        else {
            return (
                .monospacedSystemFont(ofSize: size, weight: .regular),
                .monospacedSystemFont(ofSize: size, weight: .bold)
            )
        }
        let bold = regular.fontDescriptor.withSymbolicTraits(
            regular.fontDescriptor.symbolicTraits.union(.traitBold)
        ).map { UIFont(descriptor: $0, size: size) } ?? regular
        return (regular, bold)
    }

    private static func namedFont(inFamily family: String, size: CGFloat) -> UIFont? {
        guard let name = UIFont.fontNames(forFamilyName: family).first else { return nil }
        return UIFont(name: name, size: size)
    }

    /// Every monospaced family on this device, in the order a picker should show them.
    ///
    /// "Monospaced" is measured rather than believed: `UIFontDescriptor`'s `traitMonoSpace`
    /// is not set on every face that is one, and is set on some that are not, so each family
    /// is asked to draw a narrow character and a wide one and kept when the two come out the
    /// same width. That is the property the grid actually depends on.
    static func monospacedFamilies() -> [String] {
        UIFont.familyNames
            .filter { isMonospaced(family: $0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func isMonospaced(family: String, size: CGFloat = 14) -> Bool {
        guard let font = UIFont(name: family, size: size) ?? namedFont(inFamily: family, size: size) else {
            return false
        }
        return isMonospaced(font)
    }

    static func isMonospaced(_ font: UIFont) -> Bool {
        let narrow = ("i" as NSString).size(withAttributes: [.font: font]).width
        let wide = ("W" as NSString).size(withAttributes: [.font: font]).width
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        guard narrow > 0 else { return false }
        // A tenth of a point of slack: some faces round their advances differently for
        // different glyphs, and a grid does not care about that.
        return abs(narrow - wide) < 0.1 && abs(narrow - space) < 0.1
    }

    /// The display name for a family, or the system's own description when none is chosen.
    static func displayName(family: String) -> String {
        family.isEmpty ? String(localized: "System") : family
    }
}
