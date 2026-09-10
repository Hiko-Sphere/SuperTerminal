import Foundation
import Testing

@testable import ApexTerminal

/// What happens to everything pointing at a theme when the theme goes away (D-079).
///
/// A theme id is a string held in three separate places — the app's dark theme, its light
/// theme, and any number of saved connections — and every one of them resolves at draw time
/// with a silent fallback. Delete the theme and the fallback hides the consequence: the
/// connection that was ink-blue *because it is production* becomes the same colour as
/// everything else, and nobody is told. So removal repoints, and says what it is about to cost
/// before it does it.
@Suite("The theme library")
@MainActor
struct ThemeLibraryTests {
    private func theme(_ name: String, id: String = TerminalTheme.newCustomID()) -> TerminalTheme {
        TerminalTheme(
            id: id,
            name: name,
            background: RGBColor(hex: 0x0A1620),
            foreground: RGBColor(hex: 0xE0E0E0),
            cursor: RGBColor(hex: 0x66AAFF),
            selection: RGBColor(hex: 0x335577),
            ansi: (0 ..< 16).map { RGBColor(hex: 0x101010 &+ UInt32($0) &* 0x080808) },
            appearance: .dark
        )
    }

    private func library() -> (ThemeLibrary, AppSettings, HostStore) {
        let defaults = UserDefaults(suiteName: "themelib-\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "themelib-\(UUID())")
        let hosts = HostStore(directory: directory)
        return (ThemeLibrary(settings: settings, hosts: hosts), settings, hosts)
    }

    @Test("Saving twice under one id replaces rather than doubles")
    func saveReplaces() {
        let (library, settings, _) = self.library()
        let original = theme("Ocean")
        library.save(original)
        library.save(theme("Sand"))
        #expect(settings.customThemes.count == 2)

        library.save(original.with(name: "Ocean Deep"))
        #expect(settings.customThemes.count == 2)
        #expect(settings.customThemes.first?.name == "Ocean Deep")
        // Replaced in place: a rename that sent the theme to the bottom of the list would
        // reorder a list the user arranged.
        #expect(settings.customThemes.map(\.id) == [original.id, settings.customThemes[1].id])
    }

    @Test("Deleting a theme says which connections lose their colour")
    func usageIsReported() {
        let (library, settings, hosts) = self.library()
        let ocean = theme("Ocean")
        library.save(ocean)

        #expect(library.usage(of: ocean.id).isUnused)
        #expect(library.usage(of: ocean.id).consequence == nil)

        var production = Host(name: "production", hostname: "prod.example", username: "deploy")
        production.themeID = ocean.id
        hosts.add(production)
        settings.themeID = ocean.id

        let usage = library.usage(of: ocean.id)
        #expect(usage.isAppDarkTheme)
        #expect(!usage.isAppLightTheme)
        #expect(usage.connections == ["production"])
        #expect(usage.consequence?.contains("production") == true)
    }

    @Test("Deleting a theme repoints everything that used it")
    func removalRepoints() {
        let (library, settings, hosts) = self.library()
        let ocean = theme("Ocean")
        library.save(ocean)

        var production = Host(name: "production", hostname: "prod.example", username: "deploy")
        production.themeID = ocean.id
        hosts.add(production)
        var staging = Host(name: "staging", hostname: "stage.example", username: "deploy")
        staging.themeID = ocean.id
        hosts.add(staging)
        var untouched = Host(name: "laptop", hostname: "laptop.example", username: "me")
        untouched.themeID = nil
        hosts.add(untouched)
        settings.themeID = ocean.id
        settings.lightThemeID = ocean.id

        library.remove(id: ocean.id)

        #expect(settings.customThemes.isEmpty)
        // Not left addressing an id that resolves to nothing.
        #expect(settings.themeID == TerminalTheme.midnight.id)
        #expect(settings.lightThemeID == TerminalTheme.daylight.id)
        #expect(hosts.hosts.allSatisfy { $0.themeID == nil })
        #expect(hosts.hosts.count == 3)
    }

    @Test("A connection using another theme is not disturbed")
    func removalIsNarrow() {
        let (library, settings, hosts) = self.library()
        let ocean = theme("Ocean")
        let sand = theme("Sand")
        library.save(ocean)
        library.save(sand)

        var one = Host(name: "one", hostname: "one.example", username: "me")
        one.themeID = ocean.id
        hosts.add(one)
        var two = Host(name: "two", hostname: "two.example", username: "me")
        two.themeID = sand.id
        hosts.add(two)
        settings.lightThemeID = sand.id

        library.remove(id: ocean.id)

        #expect(hosts.hosts.first { $0.name == "one" }?.themeID == nil)
        #expect(hosts.hosts.first { $0.name == "two" }?.themeID == sand.id)
        #expect(settings.lightThemeID == sand.id)
        #expect(settings.customThemes.map(\.id) == [sand.id])
    }

    @Test("An id this device does not have is reported rather than swallowed")
    func unresolvedIDs() {
        let (library, settings, _) = self.library()
        let ocean = theme("Ocean")
        library.save(ocean)

        // Nothing chosen resolves: that is "follow Settings", not a missing theme.
        #expect(library.resolves(nil))
        #expect(library.resolves(ocean.id))
        #expect(library.resolves(TerminalTheme.midnight.id))
        // A connection synced from another device names a theme that never came with it.
        #expect(!library.resolves("custom.7C7E2A0E-0000-4000-A000-000000000000"))
        #expect(settings.theme(for: true, hostOverride: "custom.missing").id == TerminalTheme.midnight.id)
    }

    @Test("A duplicate is a new theme, not the same one under a new name")
    func duplication() {
        let (library, settings, _) = self.library()
        let copy = TerminalTheme.midnight.duplicated(named: "Midnight Copy")
        library.save(copy)

        #expect(copy.id != TerminalTheme.midnight.id)
        #expect(copy.isCustom)
        #expect(copy.ansi == TerminalTheme.midnight.ansi)
        // Saving the copy did not change the built-in it came from.
        #expect(settings.allThemes.filter { $0.id == TerminalTheme.midnight.id }.count == 1)
        #expect(settings.allThemes.first { $0.id == TerminalTheme.midnight.id }?.name == TerminalTheme.midnight.name)
    }

    @Test("Changing the background moves a theme to the other side of light and dark")
    func appearanceFollowsBackground() {
        let dark = TerminalTheme.midnight.duplicated(named: "Mine")
        #expect(dark.appearance == .dark)
        let lightened = dark.with(background: RGBColor(hex: 0xFAF7F0))
        #expect(lightened.appearance == .light)
        // …and back, so the field is derived rather than latched.
        #expect(lightened.with(background: RGBColor(hex: 0x0A0A0C)).appearance == .dark)
    }
}
