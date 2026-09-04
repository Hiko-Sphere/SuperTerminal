import SwiftUI

/// Backgrounds that honour Reduce Transparency.
///
/// A material behind the key row or the find bar looks good and is unreadable for anyone
/// who has turned transparency off — which people do precisely because translucent
/// chrome over changing content is hard to read. Routing every such background through
/// one modifier means the setting is honoured everywhere rather than wherever someone
/// remembered.
struct AdaptiveBarBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(DesignTokens.Color.surfaceSecondary)
        } else {
            content.background(.bar)
        }
    }
}

struct AdaptiveOverlayBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(DesignTokens.Color.surface)
                    .stroke(DesignTokens.Color.separator, lineWidth: 1)
            )
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    /// Background for bars pinned to the edge of the screen.
    func stBarBackground() -> some View {
        modifier(AdaptiveBarBackground())
    }

    /// Background for floating panels such as the connection overlay.
    func stOverlayBackground(cornerRadius: CGFloat = DesignTokens.Radius.lg) -> some View {
        modifier(AdaptiveOverlayBackground(cornerRadius: cornerRadius))
    }
}

/// Chooses the terminal theme, honouring the system's contrast settings.
///
/// The high-contrast theme is not merely offered in a list — it is selected
/// automatically when the system asks for increased contrast, because someone who has
/// turned that on should not also have to discover a terminal-specific setting.
@MainActor
struct TerminalThemeResolver {
    let settings: AppSettings

    func theme(
        colorScheme: ColorScheme,
        differentiateWithoutColor: Bool,
        increaseContrast: Bool,
        hostOverride: String?
    ) -> TerminalTheme {
        // An explicit per-host choice always wins: someone who picked a theme for a
        // particular server meant it.
        if let hostOverride, let match = settings.allThemes.first(where: { $0.id == hostOverride }) {
            return match
        }
        if increaseContrast || differentiateWithoutColor {
            return .highContrast
        }
        return settings.theme(for: colorScheme == .dark, hostOverride: nil)
    }
}
