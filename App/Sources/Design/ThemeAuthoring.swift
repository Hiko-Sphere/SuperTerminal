import SwiftUI
import UIKit

extension TerminalTheme {
    /// Every theme the user made carries this prefix, so a custom id can never collide with
    /// a built-in one — including one added in a later version of the app.
    static let customIDPrefix = "custom."

    static func newCustomID() -> String { customIDPrefix + UUID().uuidString }

    var isCustom: Bool { id.hasPrefix(Self.customIDPrefix) }

    /// Which side of light and dark a palette belongs on, measured rather than declared.
    ///
    /// A palette's own file never says, and its name is not evidence — "Solarized Light" and
    /// "Solarized Dark" differ by two colours and a name. The background's luminance is the
    /// thing that actually decides whether the app should offer it as its light or its dark
    /// theme, so that is what is asked.
    static func appearance(forBackground background: RGBColor) -> Appearance {
        GroundLegibility.luminance(background) > 0.18 ? .light : .dark
    }

    /// This theme with one field changed, since every field is a `let`.
    func with(
        name: String? = nil,
        background: RGBColor? = nil,
        foreground: RGBColor? = nil,
        cursor: RGBColor? = nil,
        selection: RGBColor? = nil,
        ansi: [RGBColor]? = nil
    ) -> TerminalTheme {
        let newBackground = background ?? self.background
        return TerminalTheme(
            id: id,
            name: name ?? self.name,
            background: newBackground,
            foreground: foreground ?? self.foreground,
            cursor: cursor ?? self.cursor,
            selection: selection ?? self.selection,
            ansi: ansi ?? self.ansi,
            // Re-measured, not carried over: changing the background from ink to paper
            // changes which appearance this theme belongs to, and a stale answer would put
            // it on the wrong side of "match system light and dark".
            appearance: Self.appearance(forBackground: newBackground)
        )
    }

    /// A copy under a new identity, for "start from this one".
    func duplicated(named name: String) -> TerminalTheme {
        TerminalTheme(
            id: Self.newCustomID(),
            name: name,
            background: background,
            foreground: foreground,
            cursor: cursor,
            selection: selection,
            ansi: ansi,
            appearance: appearance
        )
    }

    /// A blank starting point: this app's own default, renamed and re-identified.
    static func newCustom(named name: String) -> TerminalTheme {
        TerminalTheme.midnight.duplicated(named: name)
    }
}

// MARK: - What a palette costs to read

/// What a theme's own colours measure against its own background.
///
/// Every terminal that offers theme editing lets a person build a palette they cannot read
/// and says nothing. The numbers are not an opinion and cost nothing to compute, so they are
/// shown while the colour is being chosen — the moment they can still change the outcome.
///
/// The claim made is deliberately narrow. WCAG's thresholds were written for body text on a
/// page, and a terminal cell is neither; what is reported is the contrast ratio itself, plus
/// a caution when a colour falls under 3:1, the point below which the guideline stops
/// considering *anything* legible, including large text and interface glyphs.
struct ThemeLegibility {
    /// Below this, a colour is called out by name.
    static let cautionRatio = 3.0

    let theme: TerminalTheme

    /// Default text on the theme's background.
    var foregroundRatio: Double { GroundLegibility.ratio(theme.foreground, theme.background) }

    /// The cursor block has to be findable, and it is drawn as a solid shape rather than as
    /// text, so it is measured on its own.
    var cursorRatio: Double { GroundLegibility.ratio(theme.cursor, theme.background) }

    /// Every ANSI colour against the background, in palette order.
    var ansiRatios: [Double] { theme.ansi.map { GroundLegibility.ratio($0, theme.background) } }

    /// The ANSI colours a remote program will actually print text in, weakest first.
    ///
    /// Colour 0 is excluded on purpose: it is the background colour by convention — black on
    /// a dark theme — and nothing prints text in it against itself. Including it would mean
    /// every well-formed dark theme reported a 1:1 failure it cannot fix.
    var weakest: [(index: Int, ratio: Double)] {
        theme.ansi.enumerated()
            .filter { $0.offset != 0 }
            .map { (index: $0.offset, ratio: GroundLegibility.ratio($0.element, theme.background)) }
            .sorted { $0.ratio < $1.ratio }
    }

    /// Which ANSI colours fall below the caution ratio, weakest first.
    var cautions: [(index: Int, ratio: Double)] {
        weakest.filter { $0.ratio < Self.cautionRatio }
    }

    /// One sentence, or nothing when there is nothing to say.
    var caution: String? {
        var problems: [String] = []
        if foregroundRatio < Self.cautionRatio {
            problems.append(String(localized: "the text colour is at \(ratioText(foregroundRatio))"))
        }
        let colours = cautions
        if let worst = colours.first {
            problems.append(colours.count == 1
                ? String(localized: "colour \(worst.index) is at \(ratioText(worst.ratio))")
                : String(localized: "\(colours.count) of the sixteen colours are below \(ratioText(Self.cautionRatio)), the weakest being colour \(worst.index) at \(ratioText(worst.ratio))"))
        }
        guard !problems.isEmpty else { return nil }
        return String(localized: "Against this background \(problems.joined(separator: ", and ")). Small text in those colours will be hard to read.")
    }

    func ratioText(_ ratio: Double) -> String {
        String(format: "%.1f:1", ratio)
    }
}

// MARK: - Colours across the SwiftUI boundary

extension RGBColor {
    /// The colour a `ColorPicker` produced, in sRGB.
    ///
    /// Converted through Core Graphics rather than read straight off the components: a picker
    /// on a wide-gamut display hands back a Display P3 colour, and reading those components
    /// as if they were sRGB shifts every saturated colour.
    init(_ color: Color) {
        let cgColor = UIColor(color).cgColor
        if let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
           let converted = cgColor.converted(to: sRGB, intent: .relativeColorimetric, options: nil),
           let components = converted.components, components.count >= 3 {
            self.init(clamping: Double(components[0]), Double(components[1]), Double(components[2]))
        } else if let components = cgColor.components, components.count >= 3 {
            self.init(clamping: Double(components[0]), Double(components[1]), Double(components[2]))
        } else {
            self.init(red: 0, green: 0, blue: 0)
        }
    }
}
