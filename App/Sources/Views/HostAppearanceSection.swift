import SwiftUI

/// Which theme one connection opens in.
///
/// `Host.themeID` has been read since the terminal had themes — `TerminalView` and
/// `TmuxWindowView` both pass it to the resolver — and written by nothing at all, so the
/// override existed and could not be reached. This is the entry point.
///
/// It answers a real thing people do: the reason to give one server its own colour is so that
/// the window you are typing a destructive command into is visibly not the one you meant to be
/// in. Every serious terminal has landed on the same answer, and it is worth having.
struct HostAppearanceSection: View {
    @Environment(AppContainer.self) private var container
    @Binding var themeID: String?

    private var library: ThemeLibrary {
        ThemeLibrary(settings: container.settings, hosts: container.hostStore)
    }

    /// What the terminal would actually draw with, for the preview.
    private var resolved: TerminalTheme {
        container.settings.theme(for: true, hostOverride: themeID)
    }

    /// A theme this connection asks for that this device does not have.
    ///
    /// Not hypothetical: connections sync and themes do not, so a connection set to a palette
    /// made on an iPad arrives here naming an id that resolves to nothing. The resolver falls
    /// back silently, which is right for drawing and wrong for a settings screen — somebody
    /// looking at this row would otherwise be told the connection has no theme, and "correct"
    /// it into losing the choice on the other device too.
    private var missingThemeID: String? {
        guard let themeID, !library.resolves(themeID) else { return nil }
        return themeID
    }

    var body: some View {
        Section {
            Picker(selection: $themeID) {
                Text("Same as Settings").tag(String?.none)
                ForEach(container.settings.allThemes) { theme in
                    Text(theme.name).tag(String?.some(theme.id))
                }
                if let missingThemeID {
                    Text("Not on this device").tag(String?.some(missingThemeID))
                }
            } label: {
                Text("Theme")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("host-theme")

            if missingThemeID != nil {
                Label(
                    "This connection was set to a theme that is not on this device. It opens in the default theme here. Choosing another replaces the choice everywhere this connection syncs.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(DesignTokens.Typography.callout)
                .foregroundStyle(DesignTokens.Color.warning)
                .accessibilityIdentifier("host-theme-missing")
            } else {
                TerminalThemePreview(
                    theme: resolved,
                    fontFamily: container.settings.fontFamily,
                    fontSize: 12
                )
                .listRowInsets(EdgeInsets(
                    top: DesignTokens.Spacing.sm,
                    leading: DesignTokens.Spacing.lg,
                    bottom: DesignTokens.Spacing.sm,
                    trailing: DesignTokens.Spacing.lg
                ))
                .accessibilityIdentifier("host-theme-preview")
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text(themeID == nil
                 ? "This connection follows the theme in Settings. Give the servers you would rather not confuse their own colours — the window you are about to type into then says which one it is before you read the prompt."
                 : "This connection always opens in this theme, whichever one Settings is set to. Increase Contrast still overrides it: an accessibility setting is not a preference to be outvoted by a colour.")
        }
    }
}
