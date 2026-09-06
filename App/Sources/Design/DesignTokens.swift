import SwiftUI

/// The design system's vocabulary.
///
/// Everything visual resolves through these tokens rather than through literals at call
/// sites. That is what keeps a terminal app coherent as it grows: a colour used in nine
/// places is one decision, not nine, and a theme change or an accessibility setting has
/// exactly one place to take effect.
public enum DesignTokens {
    // MARK: - Colour

    public enum Color {
        /// The single accent. Used for the active session, primary actions and focus.
        public static let accent = SwiftUI.Color("AccentColor", bundle: .main)

        public static let surface = SwiftUI.Color(uiColor: .systemBackground)
        public static let surfaceSecondary = SwiftUI.Color(uiColor: .secondarySystemBackground)
        public static let surfaceGrouped = SwiftUI.Color(uiColor: .systemGroupedBackground)
        /// A card sitting *on* `surfaceGrouped`. Not the same as `surface`: in dark mode
        /// `systemBackground` and `systemGroupedBackground` are both black, so a card
        /// painted with `surface` there is separated from its background by nothing but a
        /// hairline. This is the pair the system itself uses for grouped rows.
        public static let surfaceCard = SwiftUI.Color(uiColor: .secondarySystemGroupedBackground)
        public static let separator = SwiftUI.Color(uiColor: .separator)

        public static let label = SwiftUI.Color(uiColor: .label)
        public static let labelSecondary = SwiftUI.Color(uiColor: .secondaryLabel)
        public static let labelTertiary = SwiftUI.Color(uiColor: .tertiaryLabel)

        /// Status colours. Named for meaning, not for hue, so a theme cannot make
        /// "danger" green.
        public static let success = SwiftUI.Color(uiColor: .systemGreen)
        public static let warning = SwiftUI.Color(uiColor: .systemOrange)
        public static let danger = SwiftUI.Color(uiColor: .systemRed)
        public static let info = SwiftUI.Color(uiColor: .systemBlue)
    }

    // MARK: - Spacing

    /// A 4-point scale. Restricting spacing to a scale is what makes unrelated screens
    /// look like they belong to the same product.
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
    }

    // MARK: - Radius

    public enum Radius {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 10
        public static let lg: CGFloat = 14
        public static let xl: CGFloat = 20
        public static let pill: CGFloat = 999
    }

    // MARK: - Typography

    public enum Typography {
        /// Body text scales with Dynamic Type everywhere in the app's own chrome.
        public static let title = Font.title2.weight(.semibold)
        public static let headline = Font.headline
        public static let body = Font.body
        public static let callout = Font.callout
        public static let caption = Font.caption
        public static let monoCaption = Font.system(.caption, design: .monospaced)

        /// The terminal's own font is deliberately *not* Dynamic Type: a terminal grid
        /// has to match the geometry the remote program was told about, and a font that
        /// silently changes size would desynchronise it. Terminal size is a setting the
        /// user controls directly instead.
        public static func terminal(size: CGFloat) -> UIFont {
            UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    // MARK: - Elevation

    public enum Elevation {
        public static let card = ShadowStyle(radius: 8, y: 2, opacity: 0.08)
        public static let sheet = ShadowStyle(radius: 24, y: 8, opacity: 0.16)

        public struct ShadowStyle: Sendable {
            public let radius: CGFloat
            public let y: CGFloat
            public let opacity: Double
        }
    }

    // MARK: - Motion

    /// Motion tokens exist so that "respect Reduce Motion" is a single decision rather
    /// than a checkbox every animation has to remember.
    public enum Motion {
        public static let quick = Animation.easeOut(duration: 0.15)
        public static let standard = Animation.easeInOut(duration: 0.25)
        public static let emphasised = Animation.spring(response: 0.4, dampingFraction: 0.82)

        /// Returns `nil` — meaning "change without animating" — when the user has asked
        /// for reduced motion.
        public static func respectingReduceMotion(
            _ animation: Animation,
            reduceMotion: Bool
        ) -> Animation? {
            reduceMotion ? nil : animation
        }
    }
}

extension View {
    func stCardShadow(_ style: DesignTokens.Elevation.ShadowStyle = DesignTokens.Elevation.card) -> some View {
        shadow(color: .black.opacity(style.opacity), radius: style.radius, x: 0, y: style.y)
    }
}
