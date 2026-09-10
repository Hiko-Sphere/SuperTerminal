import Foundation

/// Adds, replaces and removes the themes a person made.
///
/// Its reason for existing is deletion. A theme is not a leaf: the app's dark theme, its light
/// theme and any number of saved connections can each be pointing at one, and every one of
/// those references is a string that resolves at draw time. Delete the theme and they all keep
/// pointing at nothing — which the resolver handles by silently falling back, so the connection
/// that was ink-blue to mark it as production quietly becomes the same colour as everything
/// else, and the person who deleted an unused-looking palette is never told.
///
/// So removal repoints every reference in the same step, and reports how many there were before
/// it does. The rule is the same one D-078 was about: a preference that silently stops meaning
/// what it said is worse than one that fails loudly.
@MainActor
struct ThemeLibrary {
    let settings: AppSettings
    let hosts: HostStore

    /// The themes the user made, in the order they were added.
    var custom: [TerminalTheme] { settings.customThemes }

    /// Inserts a new theme, or replaces the one with the same id, keeping its position.
    func save(_ theme: TerminalTheme) {
        var themes = settings.customThemes
        if let index = themes.firstIndex(where: { $0.id == theme.id }) {
            themes[index] = theme
        } else {
            themes.append(theme)
        }
        settings.customThemes = themes
    }

    /// What a deletion would take with it.
    func usage(of id: String) -> Usage {
        Usage(
            isAppDarkTheme: settings.themeID == id,
            isAppLightTheme: settings.lightThemeID == id,
            connections: hosts.hosts.filter { $0.themeID == id }.map(\.name)
        )
    }

    struct Usage: Equatable {
        var isAppDarkTheme = false
        var isAppLightTheme = false
        var connections: [String] = []

        var isUnused: Bool { !isAppDarkTheme && !isAppLightTheme && connections.isEmpty }

        /// What the confirmation says, or nothing when the theme is used by nothing.
        var consequence: String? {
            var parts: [String] = []
            if isAppDarkTheme { parts.append(String(localized: "the app's dark theme")) }
            if isAppLightTheme { parts.append(String(localized: "the app's light theme")) }
            if connections.count == 1 {
                parts.append(String(localized: "the connection “\(connections[0])”"))
            } else if connections.count > 1 {
                parts.append(String(localized: "\(connections.count) connections"))
            }
            guard !parts.isEmpty else { return nil }
            return String(localized: "This theme is in use by \(ListFormatter.localizedString(byJoining: parts)). Deleting it puts them back on the default theme.")
        }
    }

    /// Removes the theme and repoints everything that used it, so nothing is left addressing
    /// an id that no longer resolves.
    @discardableResult
    func remove(id: String) -> Usage {
        let usage = usage(of: id)
        settings.customThemes = settings.customThemes.filter { $0.id != id }
        if usage.isAppDarkTheme { settings.themeID = TerminalTheme.midnight.id }
        if usage.isAppLightTheme { settings.lightThemeID = TerminalTheme.daylight.id }
        for host in hosts.hosts where host.themeID == id {
            var updated = host
            updated.themeID = nil
            hosts.update(updated)
        }
        return usage
    }

    /// Whether an id names a theme this device actually has.
    ///
    /// A connection arrives from another device carrying whatever theme was chosen there, and
    /// themes themselves do not sync — so this returns false often enough to be worth showing
    /// rather than swallowing.
    func resolves(_ id: String?) -> Bool {
        guard let id else { return true }
        return settings.allThemes.contains { $0.id == id }
    }
}
