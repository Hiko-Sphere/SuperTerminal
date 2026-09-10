import SwiftUI

/// A miniature terminal drawn in a theme's own colours.
///
/// Choosing a palette from a list of names is choosing blind, which is why the picker in
/// Settings — a row of words — has never been enough to make the custom-theme machinery worth
/// having. What a person is actually choosing is what a prompt, a diff and an error look like
/// on their screen, so that is what is shown, in the font they have chosen, with the same
/// colour resolution the terminal itself uses.
///
/// The sample is written to exercise the colours a real session leans on: the prompt, the two
/// colours `git status` prints in, an error, dimmed detail, the selection band and the cursor.
/// It is a sample and reads as one — no output here claims to have come from a server.
struct TerminalThemePreview: View {
    let theme: TerminalTheme
    /// The terminal font family, so the preview shows the glyphs the session will use.
    var fontFamily: String = TerminalFont.systemFamily
    var fontSize: CGFloat = 12
    /// Collapses to the palette strip alone, for a list row.
    var isCompact = false

    /// One run of characters in one colour.
    private struct Run: Identifiable {
        let id = UUID()
        let text: String
        let colour: (TerminalTheme) -> RGBColor
        var isBold = false
        var isSelected = false
    }

    private static func ansi(_ index: Int) -> (TerminalTheme) -> RGBColor {
        { $0.ansi[index] }
    }

    private var lines: [[Run]] {
        [
            [
                Run(text: "apex", colour: Self.ansi(10), isBold: true),
                Run(text: " ~/site", colour: Self.ansi(12), isBold: true),
                Run(text: " $ ", colour: Self.ansi(8)),
                Run(text: "git status", colour: { $0.foreground }),
            ],
            [
                Run(text: " M ", colour: Self.ansi(3)),
                Run(text: "deploy/nginx.conf", colour: { $0.foreground }),
            ],
            [
                Run(text: " ?? ", colour: Self.ansi(1)),
                Run(text: "notes.md", colour: { $0.foreground }, isSelected: true),
            ],
            [
                Run(text: "warning:", colour: Self.ansi(11), isBold: true),
                Run(text: " 2 files not staged", colour: Self.ansi(7)),
            ],
            [
                Run(text: "apex", colour: Self.ansi(10), isBold: true),
                Run(text: " ~/site", colour: Self.ansi(12), isBold: true),
                Run(text: " $ ", colour: Self.ansi(8)),
                Run(text: "\u{2588}", colour: { $0.cursor }),
            ],
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if !isCompact {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, runs in
                        line(runs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            palette
        }
        .padding(isCompact ? DesignTokens.Spacing.xs : DesignTokens.Spacing.md)
        .background(theme.background.swiftUIColor)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
            // A pale theme on a pale sheet needs an edge, or the preview has no boundary and
            // the palette looks like part of the form.
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Color.separator, lineWidth: 0.5)
        )
        // The colours cross-fade when a different theme is chosen instead of snapping, which
        // is what makes flicking through a list of them readable rather than strobing.
        .animation(DesignTokens.Motion.standard, value: theme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview of \(theme.name)"))
    }

    private func line(_ runs: [Run]) -> some View {
        HStack(spacing: 0) {
            ForEach(runs) { run in
                Text(run.text)
                    .font(Font(TerminalFont.faces(family: fontFamily, size: fontSize).regular))
                    .fontWeight(run.isBold ? .bold : .regular)
                    .foregroundStyle(run.colour(theme).swiftUIColor)
                    .background(run.isSelected ? theme.selection.swiftUIColor : .clear)
            }
            Spacer(minLength: 0)
        }
        // The sample is fixed text in a fixed grid; letting it grow with Dynamic Type would
        // wrap a terminal line, which is the one thing a terminal never does here.
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The sixteen ANSI colours, normal above bright — the order every palette is published in.
    private var palette: some View {
        VStack(spacing: 2) {
            swatchRow(0 ..< 8)
            swatchRow(8 ..< 16)
        }
    }

    private func swatchRow(_ range: Range<Int>) -> some View {
        HStack(spacing: 2) {
            ForEach(range, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(theme.ansi[index].swiftUIColor)
                    .frame(height: isCompact ? 8 : 12)
            }
        }
    }
}
