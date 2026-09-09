import Foundation
import Testing
import UIKit

@testable import ApexTerminal

/// Which font the terminal draws with (D-063).
///
/// The property that matters is not "is this font pretty" but "does every character take
/// the same width" — a grid drawn with a proportional font does not line up, and the cursor
/// lands somewhere other than where the text is.
@Suite("Terminal fonts") @MainActor
struct TerminalFontTests {
    @Test("Monospaced is measured, not believed")
    func detectsMonospacedFonts() {
        // Menlo and Courier are monospaced; Helvetica is the textbook counter-example.
        #expect(TerminalFont.isMonospaced(family: "Menlo"))
        #expect(TerminalFont.isMonospaced(family: "Courier New"))
        #expect(!TerminalFont.isMonospaced(family: "Helvetica"))
        #expect(!TerminalFont.isMonospaced(family: "Times New Roman"))
    }

    @Test("The system's own monospaced face passes its own test")
    func systemFontIsMonospaced() {
        #expect(TerminalFont.isMonospaced(.monospacedSystemFont(ofSize: 14, weight: .regular)))
        #expect(!TerminalFont.isMonospaced(.systemFont(ofSize: 14)))
    }

    @Test("Every family offered in the picker is one the grid can use")
    func offeredFamiliesAreAllUsable() {
        let families = TerminalFont.monospacedFamilies()
        #expect(!families.isEmpty, "a device has at least Menlo")
        for family in families {
            #expect(TerminalFont.isMonospaced(family: family), "\(family) was offered and is not monospaced")
        }
        // And sorted the way a person reads a list.
        #expect(families == families.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test("A font that is not there falls back rather than failing")
    func missingFontsFallBack() {
        // A backup restored onto a device that never had the font, or a font uninstalled
        // since. A terminal that refused to draw would be the worst possible answer.
        let faces = TerminalFont.faces(family: "No Such Font At All", size: 14)
        #expect(TerminalFont.isMonospaced(faces.regular))
        #expect(faces.regular.pointSize == 14)
        #expect(faces.bold.pointSize == 14)
    }

    @Test("A chosen family is used, in both weights")
    func usesTheChosenFamily() {
        let faces = TerminalFont.faces(family: "Menlo", size: 15)
        #expect(faces.regular.familyName == "Menlo")
        #expect(faces.bold.familyName == "Menlo")
        #expect(faces.regular.fontName != faces.bold.fontName, "bold should be a different face")
        #expect(faces.regular.pointSize == 15)
    }

    @Test("Line height scales the cell, and the cell never collapses")
    func lineHeightScalesTheCell() {
        let single = TerminalRenderView.metrics(forFontSize: 14, family: "Menlo", lineHeightMultiple: 1)
        let roomy = TerminalRenderView.metrics(forFontSize: 14, family: "Menlo", lineHeightMultiple: 1.5)
        #expect(roomy.cellHeight > single.cellHeight)
        // The width is the font's, not the line height's: a taller line is not a wider one.
        #expect(roomy.cellWidth == single.cellWidth)

        // Absurd values cannot produce a zero-height cell, which would divide by zero when
        // the grid works out how many rows fit.
        let squashed = TerminalRenderView.metrics(forFontSize: 14, family: "Menlo", lineHeightMultiple: 0)
        #expect(squashed.cellHeight >= 1)
    }

    @Test("The cell is measured from the family that was chosen", arguments: ["Menlo", "Courier New", ""])
    func cellComesFromTheChosenFamily(family: String) {
        // Not "two fonts differ" — Menlo and Courier New happen to share an advance at 14pt,
        // which says nothing about the code. What matters is that the grid is measured from
        // the font actually in use, because the number of columns in the same view depends
        // on it and the server is told that number.
        let metrics = TerminalRenderView.metrics(forFontSize: 14, family: family)
        let font = TerminalFont.faces(family: family, size: 14).regular
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        #expect(metrics.cellWidth == max(1, advance.rounded(.toNearestOrEven)))
        #expect(metrics.cellHeight >= font.lineHeight - 1)
    }

    @Test("The sample in Settings is drawn the way the grid will draw it")
    func sampleMatchesTheGrid() throws {
        let sample = FontSampleView.specimen(
            family: "Menlo",
            size: 15,
            lineHeightMultiple: 1.3,
            ligaturesEnabled: false
        )
        let attributes = sample.attributes(at: 0, effectiveRange: nil)
        let font = try #require(attributes[.font] as? UIFont)
        #expect(font.familyName == "Menlo")
        #expect(font.pointSize == 15)
        #expect(attributes[.ligature] as? Int == 0)

        // The row height is the cell height, not an approximation of it: the same number
        // the terminal divides its bounds by.
        let expected = TerminalRenderView.metrics(
            forFontSize: 15,
            family: "Menlo",
            lineHeightMultiple: 1.3
        ).cellHeight
        let paragraph = try #require(attributes[.paragraphStyle] as? NSParagraphStyle)
        #expect(paragraph.minimumLineHeight == expected)
        #expect(paragraph.maximumLineHeight == expected)
    }

    @Test("The sample turns ligatures on only when they are on")
    func sampleFollowsTheLigatureSetting() throws {
        let on = FontSampleView.specimen(family: "Menlo", size: 14, lineHeightMultiple: 1, ligaturesEnabled: true)
        #expect(on.attributes(at: 0, effectiveRange: nil)[.ligature] as? Int == 1)

        // And it shows the pairs a ligature would merge, and the characters that are
        // easiest to confuse — otherwise the setting cannot be judged from the sample.
        for needle in ["!=", "->", "0O1lI"] {
            #expect(FontSampleView.specimenText.contains(needle), "the sample must show \(needle)")
        }
    }
}
