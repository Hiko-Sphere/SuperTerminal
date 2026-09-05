import Foundation
import Observation

/// User preferences.
///
/// Backed by `UserDefaults` because none of it is secret; anything that is goes to the
/// Keychain through ``CredentialVault``.
@Observable
@MainActor
final class AppSettings {
    private enum Key {
        static let themeID = "settings.themeID"
        static let lightThemeID = "settings.lightThemeID"
        static let followSystemAppearance = "settings.followSystemAppearance"
        static let fontSize = "settings.fontSize"
        static let scrollbackLimit = "settings.scrollbackLimit"
        static let keepAwakeWhileConnected = "settings.keepAwakeWhileConnected"
        static let commandHistoryEnabled = "settings.commandHistoryEnabled"
        static let confirmMultilinePaste = "settings.confirmMultilinePaste"
        static let hideContentInAppSwitcher = "settings.hideContentInAppSwitcher"
        static let cursorBlink = "settings.cursorBlink"
        static let bellEnabled = "settings.bellEnabled"
        static let keyRowVisible = "settings.keyRowVisible"
        static let automaticReconnect = "settings.automaticReconnect"

        static let all = [
            themeID, lightThemeID, followSystemAppearance, fontSize, scrollbackLimit,
            keepAwakeWhileConnected, commandHistoryEnabled, confirmMultilinePaste,
            hideContentInAppSwitcher, cursorBlink, bellEnabled, keyRowVisible,
            automaticReconnect,
        ]
    }

    private let defaults: UserDefaults

    #if DEBUG
    /// Puts every preference back to its shipped default.
    ///
    /// For automated runs only: preferences outlive an app launch, so without this a UI
    /// test inherits whatever the run before it left behind — and a test that depends on
    /// a default starts passing or failing according to what ran previously.
    func resetToDefaults() {
        for key in Key.all { defaults.removeObject(forKey: key) }
        themeID = defaults.string(forKey: Key.themeID) ?? TerminalTheme.midnight.id
        lightThemeID = defaults.string(forKey: Key.lightThemeID) ?? TerminalTheme.daylight.id
        followSystemAppearance = defaults.bool(forKey: Key.followSystemAppearance)
        fontSize = defaults.double(forKey: Key.fontSize)
        scrollbackLimit = defaults.integer(forKey: Key.scrollbackLimit)
        keepAwakeWhileConnected = defaults.bool(forKey: Key.keepAwakeWhileConnected)
        commandHistoryEnabled = defaults.bool(forKey: Key.commandHistoryEnabled)
        confirmMultilinePaste = defaults.bool(forKey: Key.confirmMultilinePaste)
        hideContentInAppSwitcher = defaults.bool(forKey: Key.hideContentInAppSwitcher)
        cursorBlink = defaults.bool(forKey: Key.cursorBlink)
        bellEnabled = defaults.bool(forKey: Key.bellEnabled)
        keyRowVisible = defaults.bool(forKey: Key.keyRowVisible)
        automaticReconnect = defaults.bool(forKey: Key.automaticReconnect)
    }
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.themeID: TerminalTheme.midnight.id,
            Key.lightThemeID: TerminalTheme.daylight.id,
            Key.followSystemAppearance: true,
            Key.fontSize: 13.0,
            Key.scrollbackLimit: 10000,
            Key.keepAwakeWhileConnected: true,
            // Command history is off by default. A terminal's history is among the most
            // sensitive things a device can hold, and a feature that records it should be
            // something a person turns on knowingly.
            Key.commandHistoryEnabled: false,
            Key.confirmMultilinePaste: true,
            Key.hideContentInAppSwitcher: true,
            Key.cursorBlink: true,
            Key.bellEnabled: true,
            // On by default on every device. The software keyboard has no Control, Esc,
            // Tab or arrows, so without this row there is no way to interrupt a running
            // command — and an iPad is as likely to be used without a keyboard as an
            // iPhone. Someone with a Magic Keyboard turns it off once.
            Key.keyRowVisible: true,
            // On by default: a phone's connection drops constantly, and a terminal that
            // needs a tap after every lift and every hand-off between Wi-Fi and cellular
            // is one nobody keeps open.
            Key.automaticReconnect: true,
        ])
        themeID = defaults.string(forKey: Key.themeID) ?? TerminalTheme.midnight.id
        lightThemeID = defaults.string(forKey: Key.lightThemeID) ?? TerminalTheme.daylight.id
        followSystemAppearance = defaults.bool(forKey: Key.followSystemAppearance)
        fontSize = defaults.double(forKey: Key.fontSize)
        scrollbackLimit = defaults.integer(forKey: Key.scrollbackLimit)
        keepAwakeWhileConnected = defaults.bool(forKey: Key.keepAwakeWhileConnected)
        commandHistoryEnabled = defaults.bool(forKey: Key.commandHistoryEnabled)
        confirmMultilinePaste = defaults.bool(forKey: Key.confirmMultilinePaste)
        hideContentInAppSwitcher = defaults.bool(forKey: Key.hideContentInAppSwitcher)
        cursorBlink = defaults.bool(forKey: Key.cursorBlink)
        bellEnabled = defaults.bool(forKey: Key.bellEnabled)
        keyRowVisible = defaults.bool(forKey: Key.keyRowVisible)
        automaticReconnect = defaults.bool(forKey: Key.automaticReconnect)
    }

    var themeID: String { didSet { defaults.set(themeID, forKey: Key.themeID) } }
    var lightThemeID: String { didSet { defaults.set(lightThemeID, forKey: Key.lightThemeID) } }
    var followSystemAppearance: Bool {
        didSet { defaults.set(followSystemAppearance, forKey: Key.followSystemAppearance) }
    }

    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Key.fontSize) }
    }

    var scrollbackLimit: Int { didSet { defaults.set(scrollbackLimit, forKey: Key.scrollbackLimit) } }
    var keepAwakeWhileConnected: Bool {
        didSet { defaults.set(keepAwakeWhileConnected, forKey: Key.keepAwakeWhileConnected) }
    }

    var automaticReconnect: Bool {
        didSet { defaults.set(automaticReconnect, forKey: Key.automaticReconnect) }
    }

    var keyRowVisible: Bool {
        didSet { defaults.set(keyRowVisible, forKey: Key.keyRowVisible) }
    }

    var commandHistoryEnabled: Bool {
        didSet { defaults.set(commandHistoryEnabled, forKey: Key.commandHistoryEnabled) }
    }

    var confirmMultilinePaste: Bool {
        didSet { defaults.set(confirmMultilinePaste, forKey: Key.confirmMultilinePaste) }
    }

    var hideContentInAppSwitcher: Bool {
        didSet { defaults.set(hideContentInAppSwitcher, forKey: Key.hideContentInAppSwitcher) }
    }

    var cursorBlink: Bool { didSet { defaults.set(cursorBlink, forKey: Key.cursorBlink) } }
    var bellEnabled: Bool { didSet { defaults.set(bellEnabled, forKey: Key.bellEnabled) } }

    /// Themes the user has defined, in addition to the built-ins.
    var customThemes: [TerminalTheme] = []

    var allThemes: [TerminalTheme] { TerminalTheme.builtIn + customThemes }

    /// The theme to use for a given system appearance.
    func theme(for isDark: Bool, hostOverride: String?) -> TerminalTheme {
        if let hostOverride, let match = allThemes.first(where: { $0.id == hostOverride }) {
            return match
        }
        let identifier = followSystemAppearance ? (isDark ? themeID : lightThemeID) : themeID
        return allThemes.first { $0.id == identifier } ?? .midnight
    }

    /// Font size is clamped rather than free-form: below this the grid is unreadable on a
    /// phone, and above it a useful number of columns will not fit.
    static let fontSizeRange: ClosedRange<Double> = 8 ... 28
}
