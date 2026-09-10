import Foundation
import Testing

@testable import ApexTerminal

/// What a palette costs to read, measured while it is being made (D-079).
///
/// The reason this exists is that every terminal with a theme editor lets a person build a
/// palette they cannot read and says nothing about it. The numbers are not opinions.
@Suite("Theme legibility")
struct ThemeLegibilityTests {
    private func theme(background: UInt32, foreground: UInt32, ansi: [UInt32]) -> TerminalTheme {
        TerminalTheme(
            id: "test",
            name: "Test",
            background: RGBColor(hex: background),
            foreground: RGBColor(hex: foreground),
            cursor: RGBColor(hex: foreground),
            selection: RGBColor(hex: 0x335577),
            ansi: ansi.map { RGBColor(hex: $0) },
            appearance: .dark
        )
    }

    private var flat: [UInt32] { Array(repeating: 0xBBBBBB, count: 16) }

    @Test("The ratios are WCAG's, on the endpoints anybody can check")
    func knownRatios() {
        let blackOnWhite = ThemeLegibility(theme: theme(background: 0xFFFFFF, foreground: 0x000000, ansi: flat))
        // Black on white is 21:1 exactly. Any other answer means the luminance is wrong.
        #expect(abs(blackOnWhite.foregroundRatio - 21) < 0.001)

        let same = ThemeLegibility(theme: theme(background: 0x808080, foreground: 0x808080, ansi: flat))
        #expect(abs(same.foregroundRatio - 1) < 0.001)
    }

    @Test("Colour 0 is left out of the weakest reading")
    func backgroundColourIsNotAFailure() {
        // Colour 0 is black by convention, and on a black background it is 1:1 — which is
        // correct and unfixable, because nothing prints text in it against itself. Counting
        // it would make every well-formed dark theme report a failure it cannot act on.
        var palette = Array(repeating: UInt32(0xCCCCCC), count: 16)
        palette[0] = 0x000000
        let measure = ThemeLegibility(theme: theme(background: 0x000000, foreground: 0xEEEEEE, ansi: palette))

        #expect(measure.ansiRatios[0] == 1)
        #expect(measure.weakest.allSatisfy { $0.index != 0 })
        #expect(measure.cautions.isEmpty)
        #expect(measure.caution == nil)
    }

    @Test("A colour nobody could read is named")
    func cautionNamesTheColour() {
        var palette = Array(repeating: UInt32(0xCCCCCC), count: 16)
        palette[4] = 0x0A0A40 // near-black blue on a black background
        let measure = ThemeLegibility(theme: theme(background: 0x000000, foreground: 0xEEEEEE, ansi: palette))

        #expect(measure.cautions.map(\.index) == [4])
        let caution = try! #require(measure.caution)
        #expect(caution.contains("4"))
        #expect(measure.weakest.first?.index == 4)
    }

    @Test("Unreadable body text is called out even when the palette is fine")
    func foregroundCaution() {
        let measure = ThemeLegibility(theme: theme(background: 0x101010, foreground: 0x252525, ansi: flat))
        #expect(measure.foregroundRatio < ThemeLegibility.cautionRatio)
        #expect(try! #require(measure.caution).contains("text colour"))
    }

    @Test("Every built-in theme passes its own check")
    func builtInsAreLegible() {
        for theme in TerminalTheme.builtIn {
            let measure = ThemeLegibility(theme: theme)
            #expect(measure.foregroundRatio >= 4.5, "\(theme.name) text is \(measure.foregroundRatio)")
            #expect(measure.cursorRatio >= ThemeLegibility.cautionRatio, "\(theme.name) cursor is \(measure.cursorRatio)")
            #expect(
                measure.cautions.isEmpty,
                "\(theme.name) has colours below \(ThemeLegibility.cautionRatio):1 — \(measure.cautions)"
            )
        }
    }

    @Test("The weakest list is ordered and complete")
    func ordering() {
        let palette: [UInt32] = [
            0x000000, 0x101010, 0x202020, 0x303030, 0x404040, 0x505050, 0x606060, 0x707070,
            0x808080, 0x909090, 0xA0A0A0, 0xB0B0B0, 0xC0C0C0, 0xD0D0D0, 0xE0E0E0, 0xF0F0F0,
        ]
        let measure = ThemeLegibility(theme: theme(background: 0x000000, foreground: 0xFFFFFF, ansi: palette))
        #expect(measure.weakest.count == 15)
        #expect(measure.weakest.map(\.index) == Array(1 ... 15))
        #expect(zip(measure.weakest, measure.weakest.dropFirst()).allSatisfy { $0.ratio <= $1.ratio })
    }
}
