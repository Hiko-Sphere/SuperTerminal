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
        static let clipboardExpirySeconds = "settings.clipboardExpirySeconds"
        static let keepAwakeWhileConnected = "settings.keepAwakeWhileConnected"
        static let commandHistoryEnabled = "settings.commandHistoryEnabled"
        static let spotlightEnabled = "settings.spotlightEnabled"
        static let remoteClipboardWrites = "settings.remoteClipboardWrites"
        static let confirmMultilinePaste = "settings.confirmMultilinePaste"
        static let hideContentInAppSwitcher = "settings.hideContentInAppSwitcher"
        static let cursorBlink = "settings.cursorBlink"
        static let bellEnabled = "settings.bellEnabled"
        static let keyRowVisible = "settings.keyRowVisible"
        static let automaticReconnect = "settings.automaticReconnect"
        static let hapticsEnabled = "settings.hapticsEnabled"
        static let iCloudSyncEnabled = "settings.iCloudSyncEnabled"
        static let acceptedTermsVersion = "settings.acceptedTermsVersion"
        static let hasSeenTutorial = "settings.hasSeenTutorial"
        static let assistantPrefersOnDevice = "settings.assistantPrefersOnDevice"
        static let assistantEndpoint = "settings.assistantEndpoint"
        static let assistantModel = "settings.assistantModel"
        static let appLockEnabled = "settings.appLockEnabled"
        static let appLockUsesBiometrics = "settings.appLockUsesBiometrics"
        static let appLockGraceSeconds = "settings.appLockGraceSeconds"

        static let all = [
            themeID, lightThemeID, followSystemAppearance, fontSize, scrollbackLimit, clipboardExpirySeconds,
            keepAwakeWhileConnected, commandHistoryEnabled, spotlightEnabled, remoteClipboardWrites,
            confirmMultilinePaste,
            hideContentInAppSwitcher, cursorBlink, bellEnabled, keyRowVisible,
            automaticReconnect, hapticsEnabled, iCloudSyncEnabled, acceptedTermsVersion, hasSeenTutorial,
            assistantPrefersOnDevice, assistantEndpoint, assistantModel,
            appLockEnabled, appLockUsesBiometrics, appLockGraceSeconds,
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
        clipboardExpirySeconds = defaults.integer(forKey: Key.clipboardExpirySeconds)
        keepAwakeWhileConnected = defaults.bool(forKey: Key.keepAwakeWhileConnected)
        commandHistoryEnabled = defaults.bool(forKey: Key.commandHistoryEnabled)
        spotlightEnabled = defaults.bool(forKey: Key.spotlightEnabled)
        remoteClipboardWrites = defaults.bool(forKey: Key.remoteClipboardWrites)
        confirmMultilinePaste = defaults.bool(forKey: Key.confirmMultilinePaste)
        hideContentInAppSwitcher = defaults.bool(forKey: Key.hideContentInAppSwitcher)
        cursorBlink = defaults.bool(forKey: Key.cursorBlink)
        bellEnabled = defaults.bool(forKey: Key.bellEnabled)
        keyRowVisible = defaults.bool(forKey: Key.keyRowVisible)
        automaticReconnect = defaults.bool(forKey: Key.automaticReconnect)
        hapticsEnabled = defaults.bool(forKey: Key.hapticsEnabled)
        iCloudSyncEnabled = defaults.bool(forKey: Key.iCloudSyncEnabled)
        acceptedTermsVersion = defaults.integer(forKey: Key.acceptedTermsVersion)
        hasSeenTutorial = defaults.bool(forKey: Key.hasSeenTutorial)
        assistantPrefersOnDevice = defaults.bool(forKey: Key.assistantPrefersOnDevice)
        appLockEnabled = defaults.bool(forKey: Key.appLockEnabled)
        appLockUsesBiometrics = defaults.bool(forKey: Key.appLockUsesBiometrics)
        appLockGraceSeconds = defaults.integer(forKey: Key.appLockGraceSeconds)
        assistantEndpoint = defaults.string(forKey: Key.assistantEndpoint) ?? ""
        assistantModel = defaults.string(forKey: Key.assistantModel) ?? ""
    }
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.themeID: TerminalTheme.midnight.id,
            Key.lightThemeID: TerminalTheme.daylight.id,
            // The assistant prefers the on-device model, where the device has one; the
            // provider fields name the common default so a pasted key is enough (D-020).
            Key.assistantPrefersOnDevice: true,
            Key.appLockUsesBiometrics: true,
            Key.assistantEndpoint: "https://api.openai.com/v1",
            Key.assistantModel: "gpt-4o-mini",
            Key.followSystemAppearance: true,
            Key.fontSize: Self.defaultFontSize,
            Key.scrollbackLimit: 10000,
            Key.clipboardExpirySeconds: 60,
            Key.keepAwakeWhileConnected: true,
            // Command history is off by default. A terminal's history is among the most
            // sensitive things a device can hold, and a feature that records it should be
            // something a person turns on knowingly.
            Key.commandHistoryEnabled: false,
            Key.spotlightEnabled: false,
            Key.remoteClipboardWrites: false,
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
            Key.hapticsEnabled: true,
            // Off by default. Syncing keys and hosts to iCloud is a decision a person makes
            // knowingly, and this app has promised that nothing leaves the device unless
            // they do. The switch is where that promise is kept or set aside.
            Key.iCloudSyncEnabled: false,
            // Zero means never accepted. Compared against the current Terms version so a
            // material change is shown again rather than assumed agreed.
            Key.acceptedTermsVersion: 0,
            Key.hasSeenTutorial: false,
        ])
        themeID = defaults.string(forKey: Key.themeID) ?? TerminalTheme.midnight.id
        lightThemeID = defaults.string(forKey: Key.lightThemeID) ?? TerminalTheme.daylight.id
        followSystemAppearance = defaults.bool(forKey: Key.followSystemAppearance)
        fontSize = defaults.double(forKey: Key.fontSize)
        scrollbackLimit = defaults.integer(forKey: Key.scrollbackLimit)
        clipboardExpirySeconds = defaults.integer(forKey: Key.clipboardExpirySeconds)
        keepAwakeWhileConnected = defaults.bool(forKey: Key.keepAwakeWhileConnected)
        commandHistoryEnabled = defaults.bool(forKey: Key.commandHistoryEnabled)
        spotlightEnabled = defaults.bool(forKey: Key.spotlightEnabled)
        remoteClipboardWrites = defaults.bool(forKey: Key.remoteClipboardWrites)
        confirmMultilinePaste = defaults.bool(forKey: Key.confirmMultilinePaste)
        hideContentInAppSwitcher = defaults.bool(forKey: Key.hideContentInAppSwitcher)
        cursorBlink = defaults.bool(forKey: Key.cursorBlink)
        bellEnabled = defaults.bool(forKey: Key.bellEnabled)
        keyRowVisible = defaults.bool(forKey: Key.keyRowVisible)
        automaticReconnect = defaults.bool(forKey: Key.automaticReconnect)
        hapticsEnabled = defaults.bool(forKey: Key.hapticsEnabled)
        iCloudSyncEnabled = defaults.bool(forKey: Key.iCloudSyncEnabled)
        acceptedTermsVersion = defaults.integer(forKey: Key.acceptedTermsVersion)
        hasSeenTutorial = defaults.bool(forKey: Key.hasSeenTutorial)
        assistantPrefersOnDevice = defaults.bool(forKey: Key.assistantPrefersOnDevice)
        appLockEnabled = defaults.bool(forKey: Key.appLockEnabled)
        appLockUsesBiometrics = defaults.bool(forKey: Key.appLockUsesBiometrics)
        appLockGraceSeconds = defaults.integer(forKey: Key.appLockGraceSeconds)
        assistantEndpoint = defaults.string(forKey: Key.assistantEndpoint) ?? ""
        assistantModel = defaults.string(forKey: Key.assistantModel) ?? ""
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
    /// Seconds after which text copied from the terminal leaves the pasteboard; 0 keeps
    /// it until replaced. Public keys copied from the key list are not subject to this.
    var clipboardExpirySeconds: Int { didSet { defaults.set(clipboardExpirySeconds, forKey: Key.clipboardExpirySeconds) } }
    var keepAwakeWhileConnected: Bool {
        didSet { defaults.set(keepAwakeWhileConnected, forKey: Key.keepAwakeWhileConnected) }
    }

    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) }
    }

    var iCloudSyncEnabled: Bool {
        didSet { defaults.set(iCloudSyncEnabled, forKey: Key.iCloudSyncEnabled) }
    }

    /// Whether the tour has been seen — finished or skipped, which are the same thing as
    /// far as showing it unasked is concerned. It stays on this device: a tour is about
    /// learning the interface in front of you, so syncing it would hide it from someone
    /// picking up their second device for the first time.
    var hasSeenTutorial: Bool { didSet { defaults.set(hasSeenTutorial, forKey: Key.hasSeenTutorial) } }

    var acceptedTermsVersion: Int {
        didSet { defaults.set(acceptedTermsVersion, forKey: Key.acceptedTermsVersion) }
    }
    var assistantPrefersOnDevice: Bool {
        didSet { defaults.set(assistantPrefersOnDevice, forKey: Key.assistantPrefersOnDevice) }
    }
    var assistantEndpoint: String { didSet { defaults.set(assistantEndpoint, forKey: Key.assistantEndpoint) } }
    var assistantModel: String { didSet { defaults.set(assistantModel, forKey: Key.assistantModel) } }
    /// The app lock (D-023). The setting alone locks nothing: a passcode record in the
    /// Keychain is needed too, so deleting all data cannot lock the user out.
    var appLockEnabled: Bool { didSet { defaults.set(appLockEnabled, forKey: Key.appLockEnabled) } }
    var appLockUsesBiometrics: Bool { didSet { defaults.set(appLockUsesBiometrics, forKey: Key.appLockUsesBiometrics) } }
    var appLockGraceSeconds: Int { didSet { defaults.set(appLockGraceSeconds, forKey: Key.appLockGraceSeconds) } }

    var automaticReconnect: Bool {
        didSet { defaults.set(automaticReconnect, forKey: Key.automaticReconnect) }
    }

    var keyRowVisible: Bool {
        didSet { defaults.set(keyRowVisible, forKey: Key.keyRowVisible) }
    }

    var commandHistoryEnabled: Bool {
        didSet { defaults.set(commandHistoryEnabled, forKey: Key.commandHistoryEnabled) }
    }

    /// Whether a remote program may put things on this device's clipboard — OSC 52
    /// (D-062).
    ///
    /// Off by default. `tmux`, `vim` and others use it to make "yank" reach the local
    /// clipboard, which is genuinely useful over SSH; it is also a program on somebody
    /// else's machine writing into the place this device keeps what was copied, and the
    /// person may not be looking at the screen when it happens. The *read* half of OSC 52
    /// is refused whatever this says: answering it would hand the far side whatever was
    /// last copied here.
    var remoteClipboardWrites: Bool {
        didSet { defaults.set(remoteClipboardWrites, forKey: Key.remoteClipboardWrites) }
    }

    /// Whether saved connections are offered in Spotlight (D-061).
    ///
    /// Off by default, and deliberately so: indexing hands the names and addresses of the
    /// servers somebody administers to the system's search index, where they appear in a
    /// list anybody holding the unlocked device can scroll. That is a reasonable trade for
    /// somebody with twenty connections and a poor one for somebody with one they would
    /// rather not name out loud, so it is theirs to make.
    var spotlightEnabled: Bool {
        didSet { defaults.set(spotlightEnabled, forKey: Key.spotlightEnabled) }
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
    static let defaultFontSize = 13.0
}
