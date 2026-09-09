import SwiftUI
import UIKit

/// What the chosen font will actually look like in the terminal (D-063).
///
/// A list of family names is not enough to choose a terminal font by: what matters is
/// whether a zero can be told from an `O`, whether a one can be told from an `l`, and what
/// happens to `!=` when ligatures are on. So the sample is drawn with the same face, the
/// same row height the grid will use — `TerminalRenderView.metrics` computes it, and this
/// pins the line to exactly that — and the same ligature setting.
struct FontSampleView: UIViewRepresentable {
    let family: String
    let size: CGFloat
    let lineHeightMultiple: CGFloat
    let ligaturesEnabled: Bool

    /// The characters a terminal font is judged by: the ones that are hard to tell apart,
    /// and the pairs a ligature would merge into one glyph.
    static let specimenText = "0O1lI  `'\"  {}[]()\n!= -> => >=  ~/.ssh"

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byClipping
        label.accessibilityIdentifier = "settings-font-sample"
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.attributedText = Self.specimen(
            family: family,
            size: size,
            lineHeightMultiple: lineHeightMultiple,
            ligaturesEnabled: ligaturesEnabled
        )
        label.accessibilityLabel = String(
            localized: "Sample of \(TerminalFont.displayName(family: family))",
            comment: "Accessibility label for the font preview in Settings. The placeholder is a font name."
        )
    }

    /// The sample, drawn the way the grid draws it.
    static func specimen(
        family: String,
        size: CGFloat,
        lineHeightMultiple: CGFloat,
        ligaturesEnabled: Bool
    ) -> NSAttributedString {
        let metrics = TerminalRenderView.metrics(
            forFontSize: size,
            family: family,
            lineHeightMultiple: lineHeightMultiple
        )
        let paragraph = NSMutableParagraphStyle()
        // Not `lineHeightMultiple`: the terminal gives every row exactly this many points,
        // so the sample does too rather than approximating it.
        paragraph.minimumLineHeight = metrics.cellHeight
        paragraph.maximumLineHeight = metrics.cellHeight
        return NSAttributedString(string: specimenText, attributes: [
            .font: TerminalFont.faces(family: family, size: size).regular,
            .ligature: ligaturesEnabled ? 1 : 0,
            .paragraphStyle: paragraph,
            .foregroundColor: UIColor.label,
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        // An unspecified width means "as narrow as you like"; the sample is two short
        // lines, so a phone-width guess is a safe floor rather than a layout decision.
        let width = proposal.width ?? 320
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
