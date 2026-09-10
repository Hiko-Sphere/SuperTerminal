import Foundation
import Testing

@testable import ApexTerminal

/// Themes a person defined, and whether they are still there tomorrow (D-078).
///
/// `AppSettings.customThemes` was the one setting in that file with no `didSet` writing it back —
/// a plain in-memory array. `BackupService` restores into it, so restoring a backup put the themes
/// in the picker, and the next launch took them away with nothing said. A connection whose
/// `themeID` pointed at one changed appearance at the same time, for the same silent reason.
@Suite("Custom themes survive a relaunch")
@MainActor
struct CustomThemePersistenceTests {
    private func theme(_ id: String, background: UInt32) -> TerminalTheme {
        TerminalTheme(
            id: id,
            name: id.capitalized,
            background: RGBColor(hex: background),
            foreground: RGBColor(hex: 0xE0E0E0),
            cursor: RGBColor(hex: 0x66AAFF),
            selection: RGBColor(hex: 0x335577),
            ansi: (0 ..< 16).map { RGBColor(hex: 0x101010 &+ UInt32($0) &* 0x080808) },
            appearance: .dark
        )
    }

    @Test("A theme defined in one launch is there in the next")
    func themesSurvive() throws {
        let suite = "themes-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        first.customThemes = [theme("ocean", background: 0x0A1620)]

        // A second instance over the same defaults is what the next launch is.
        let second = AppSettings(defaults: defaults)
        #expect(second.customThemes.map(\.id) == ["ocean"])
        #expect(second.customThemes.first?.background == RGBColor(hex: 0x0A1620))
        #expect(second.allThemes.contains { $0.id == "ocean" })
    }

    @Test("A connection pointing at a custom theme still gets it after a relaunch")
    func aHostOverrideStillResolves() throws {
        // The second-order loss: the theme vanishing also silently changed the appearance of
        // every connection that had chosen it.
        let suite = "themes-host-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        first.customThemes = [theme("ocean", background: 0x0A1620)]

        let second = AppSettings(defaults: defaults)
        #expect(second.theme(for: true, hostOverride: "ocean").id == "ocean")
    }

    @Test("Restoring a backup keeps the themes it restored")
    func aRestoredBackupSurvives() throws {
        let suite = "themes-backup-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // What `BackupService.apply` does with a backup that carries themes.
        let restoring = AppSettings(defaults: defaults)
        restoring.customThemes = [theme("ocean", background: 0x0A1620), theme("sand", background: 0xF5EFE2)]

        let afterRelaunch = AppSettings(defaults: defaults)
        #expect(afterRelaunch.customThemes.count == 2)
        #expect(Set(afterRelaunch.customThemes.map(\.id)) == ["ocean", "sand"])
    }

    @Test("Removing the last one leaves nothing behind")
    func removingClearsTheKey() throws {
        let suite = "themes-clear-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customThemes = [theme("ocean", background: 0x0A1620)]
        settings.customThemes = []

        #expect(defaults.data(forKey: "settings.customThemes") == nil)
        #expect(AppSettings(defaults: defaults).customThemes.isEmpty)
    }

    @Test("A reset clears them, which needs the key to be listed")
    func aResetTakesThemToo() throws {
        // `resetToDefaults()` iterates `Key.all`; a key missing from that list survives a reset
        // and decides the next run's appearance. Driven through the behaviour rather than the
        // private list, which is what a test should be checking anyway.
        let suite = "themes-reset-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customThemes = [theme("ocean", background: 0x0A1620)]
        settings.resetToDefaults()

        #expect(settings.customThemes.isEmpty)
        #expect(AppSettings(defaults: defaults).customThemes.isEmpty)
    }
}
