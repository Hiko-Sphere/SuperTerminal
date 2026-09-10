import Foundation

/// Whether the wallpaper is shown at all, given what the person has asked the system for (D-077).
///
/// Beside ``TerminalThemeResolver`` and for the same reason: two call sites — a terminal and a
/// tmux window — must not drift apart on a question this important.
///
/// Turning the picture **off** rather than dimming it further is the honest reading of these
/// settings. Reduce Transparency is a request for fewer things behind text; a fainter photograph
/// is still a photograph behind text.
@MainActor
struct BackdropResolver {
    func backdrop(
        _ stored: Backdrop?,
        reduceTransparency: Bool,
        increaseContrast: Bool,
        differentiateWithoutColor: Bool
    ) -> Backdrop? {
        guard !reduceTransparency, !increaseContrast, !differentiateWithoutColor else { return nil }
        return stored
    }

    /// Which setting took the picture away, for the note that says so.
    ///
    /// A control that silently does nothing is the worst version of this feature: the person
    /// chose a picture, the picture is not there, and nothing on screen connects the two.
    func suppressionReason(
        reduceTransparency: Bool,
        increaseContrast: Bool,
        differentiateWithoutColor: Bool
    ) -> String? {
        if reduceTransparency {
            return String(localized: "Reduce Transparency is on, so the picture is not shown. The terminal uses its theme colour instead.")
        }
        if increaseContrast {
            return String(localized: "Increase Contrast is on, so the picture is not shown. The terminal uses its theme colour instead.")
        }
        if differentiateWithoutColor {
            return String(localized: "Differentiate Without Colour is on, so the picture is not shown. The terminal uses its theme colour instead.")
        }
        return nil
    }
}
