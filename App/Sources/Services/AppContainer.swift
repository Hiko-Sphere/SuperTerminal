import Foundation
import NIOTransportServices
import Observation
import STCloudflare
import STCore
import STSSH

/// The application's composition root.
///
/// Everything with a lifetime longer than a view is created here and passed down. There
/// is no global mutable state: a terminal app opens sockets and reads private keys, and
/// a singleton would make it impossible to answer "what can reach the Keychain?" by
/// reading the code.
@Observable
@MainActor
final class AppContainer {
    let hostStore: HostStore
    /// Saved remote screens (D-027), separate from the SSH connections.
    let screenStore: ScreenStore
    let snippetStore: SnippetStore
    let restoration: SessionRestorationStore
    let sessionManager: SessionManager
    let settings: AppSettings
    let reachability: NetworkReachability
    let haptics: Haptics
    let vault: CredentialVault
    let knownHosts: any KnownHostsStore
    /// Export and restore (D-040). Built on first use — most launches never open
    /// Settings — and ignored by observation because it holds no state a view watches.
    /// A file-browsing session for one connection (D-042).
    func makeFileSession(for host: Host) -> SFTPSession {
        sessionManager.makeFileSession(for: host)
    }

    @ObservationIgnored lazy var backup: BackupService = BackupService(
        hosts: hostStore, screens: screenStore, snippets: snippetStore,
        knownHosts: knownHosts, settings: settings, vault: vault, log: diagnostics.logger
    )
    let diagnostics: DiagnosticsCentre
    let sync: SyncCoordinator
    /// App-level keyboard shortcuts; every responder that exposes them routes here.
    let shortcuts: AppShortcutRouter
    /// The assistant: chooses an engine per request and holds the answer (D-020).
    let assistant: AssistantCoordinator
    /// Remote screens (D-022), kept apart from the terminal sessions.
    let screens: VNCSessionManager
    /// The app lock (D-023) and the windows it is shown in.
    let appLock: AppLock
    let lockWindows = AppLockWindows()
    /// A session an App Intent opened before any scene could show it (D-021). The root
    /// view consumes it on appearance and clears it.
    var pendingIntentSessionID: TerminalSession.ID?
    /// The scene most recently active. Menu commands target the *focused* scene when
    /// SwiftUI reports one, and this otherwise: on iOS the focused-scene value is only
    /// published while some view has focus, which a freshly launched host list does not —
    /// and a ⌘K that does nothing until you tap a text field is a broken shortcut.
    var activeScene: SceneState?

    private init(
        hostStore: HostStore,
        screenStore: ScreenStore,
        snippetStore: SnippetStore,
        restoration: SessionRestorationStore,
        sessionManager: SessionManager,
        settings: AppSettings,
        reachability: NetworkReachability,
        haptics: Haptics,
        vault: CredentialVault,
        knownHosts: any KnownHostsStore,
        diagnostics: DiagnosticsCentre,
        sync: SyncCoordinator,
        shortcuts: AppShortcutRouter,
        assistant: AssistantCoordinator,
        screens: VNCSessionManager,
        appLock: AppLock
    ) {
        self.hostStore = hostStore
        self.screenStore = screenStore
        self.snippetStore = snippetStore
        self.restoration = restoration
        self.sessionManager = sessionManager
        self.settings = settings
        self.reachability = reachability
        self.haptics = haptics
        self.vault = vault
        self.knownHosts = knownHosts
        self.diagnostics = diagnostics
        self.sync = sync
        self.shortcuts = shortcuts
        self.assistant = assistant
        self.screens = screens
        self.appLock = appLock
    }

    static func live() -> AppContainer {
        let directory = HostStore.defaultDirectory()
        let diagnostics = DiagnosticsCentre()
        let vault = CredentialVault()
        let knownHosts = FileKnownHostsStore(
            url: directory.appendingPathComponent("known_hosts.json"),
            log: diagnostics.logger
        )
        let settings = AppSettings()
        let reachability = NetworkReachability()
        let haptics = Haptics(settings: settings)
        let restoration = SessionRestorationStore(directory: directory)
        let sessionManager = SessionManager(
            vault: vault,
            knownHosts: knownHosts,
            settings: settings,
            diagnostics: diagnostics,
            reachability: reachability,
            restoration: restoration,
            haptics: haptics
        )
        let hostStore = HostStore(directory: directory)
        let screenStore = ScreenStore(directory: directory)
        let snippetStore = SnippetStore(directory: directory, settings: settings)
        let tombstones = SyncTombstones(directory: directory)
        hostStore.tombstones = tombstones
        screenStore.tombstones = tombstones
        snippetStore.tombstones = tombstones
        // Before anything can sync: a screen configured inside a connection becomes its
        // own record, on this device, once (D-027).
        ScreenMigration.runAtLaunch(hosts: hostStore, screens: screenStore, vault: vault, log: diagnostics.logger)
        let sync = SyncCoordinator(
            settings: settings,
            directory: directory,
            local: AppSyncStore(hosts: hostStore, screens: screenStore, snippets: snippetStore, knownHosts: knownHosts, tombstones: tombstones),
            tombstones: tombstones,
            log: diagnostics.logger
        )
        hostStore.didChange = { [weak sync] in sync?.scheduleSync() }
        screenStore.didChange = { [weak sync] in sync?.scheduleSync() }
        snippetStore.didChange = { [weak sync] in sync?.scheduleSync() }
        sessionManager.didConnect = { [weak sync] in sync?.scheduleSync() }
        sessionManager.didDetectPlatform = { [weak hostStore] id, platform in
            hostStore?.recordDetectedPlatform(platform, forHostID: id)
        }
        let shortcuts = AppShortcutRouter(sessionManager: sessionManager, settings: settings)
        let assistant = AssistantCoordinator(settings: settings, vault: vault, log: diagnostics.logger)
        let screens = VNCSessionManager(vault: vault, knownHosts: knownHosts, diagnostics: diagnostics, haptics: haptics)
        let appLock = AppLock(settings: settings, vault: vault, log: diagnostics.logger)
        let container = AppContainer(
            hostStore: hostStore,
            screenStore: screenStore,
            snippetStore: snippetStore,
            restoration: restoration,
            sessionManager: sessionManager,
            settings: settings,
            reachability: reachability,
            haptics: haptics,
            vault: vault,
            knownHosts: knownHosts,
            diagnostics: diagnostics,
            sync: sync,
            shortcuts: shortcuts,
            assistant: assistant,
            screens: screens, appLock: appLock
        )
        shortcuts.sceneProvider = { [weak container] in container?.activeScene }
        #if DEBUG
        UITestSeeding.apply(to: container)
        #endif
        return container
    }

    #if DEBUG
    /// The same graph as `live()`, on stores in `directory`, for tests that need a whole
    /// container — App Intents reach one through the dependency registry (D-021).
    static func testInstance(directory: URL) -> AppContainer {
        let diagnostics = DiagnosticsCentre()
        let vault = CredentialVault()
        let knownHosts = FileKnownHostsStore(url: directory.appendingPathComponent("known_hosts.json"), log: diagnostics.logger)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)") ?? .standard)
        let reachability = NetworkReachability()
        let haptics = Haptics(settings: settings)
        let restoration = SessionRestorationStore(directory: directory)
        let sessionManager = SessionManager(
            vault: vault, knownHosts: knownHosts, settings: settings, diagnostics: diagnostics,
            reachability: reachability, restoration: restoration, haptics: haptics
        )
        let hostStore = HostStore(directory: directory)
        let screenStore = ScreenStore(directory: directory)
        let snippetStore = SnippetStore(directory: directory, settings: settings)
        let tombstones = SyncTombstones(directory: directory)
        let sync = SyncCoordinator(
            settings: settings, directory: directory,
            local: AppSyncStore(hosts: hostStore, screens: screenStore, snippets: snippetStore, knownHosts: knownHosts, tombstones: tombstones),
            tombstones: tombstones, log: diagnostics.logger
        )
        let shortcuts = AppShortcutRouter(sessionManager: sessionManager, settings: settings)
        let assistant = AssistantCoordinator(settings: settings, vault: vault, log: diagnostics.logger)
        let screens = VNCSessionManager(vault: vault, knownHosts: knownHosts, diagnostics: diagnostics, haptics: haptics)
        let appLock = AppLock(settings: settings, vault: vault, log: diagnostics.logger)
        let container = AppContainer(
            hostStore: hostStore, screenStore: screenStore, snippetStore: snippetStore, restoration: restoration, sessionManager: sessionManager,
            settings: settings, reachability: reachability, haptics: haptics, vault: vault, knownHosts: knownHosts,
            diagnostics: diagnostics, sync: sync, shortcuts: shortcuts, assistant: assistant, screens: screens, appLock: appLock
        )
        shortcuts.sceneProvider = { [weak container] in container?.activeScene }
        return container
    }
    #endif
}

/// Collects redacted log records and vends the logger the rest of the app uses.
@MainActor
final class DiagnosticsCentre {
    let buffer = RingBufferLogSink(capacity: 2000)
    let logger: STLogger

    init() {
        logger = STLogger(
            subsystem: "ApexTerminal",
            sinks: [buffer, OSLogSink(subsystem: "dev.apexterminal", category: "app")],
            minimumLevel: .info
        )
    }

    /// Builds an exportable report.
    ///
    /// Everything in the buffer was redacted when it was written, so this is a plain
    /// serialisation rather than a scrubbing pass — which is the only way to be confident
    /// a diagnostics export is safe to send to someone.
    func exportReport() -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            String(localized: "Apex Terminal diagnostics"),
            String(localized: "Generated: \(formatter.string(from: Date()))"),
            "",
            String(localized: "Records are redacted at the point they are written: no commands, terminal output, hostnames, passwords, keys or tokens are captured."),
            "",
        ]
        for record in buffer.snapshot() {
            lines.append("\(formatter.string(from: record.timestamp)) \(record.rendered)")
        }
        return lines.joined(separator: "\n")
    }
}
