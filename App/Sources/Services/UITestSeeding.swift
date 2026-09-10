import Foundation
import STForwarding
import STSSH

#if DEBUG
/// Seeds a connection from the environment so automated UI runs can reach a live
/// terminal.
///
/// Compiled only into Debug builds, so it cannot exist in anything shipped. It is here
/// because the terminal screen — the app's most important surface — is otherwise
/// unreachable from a UI test: getting to it needs a server, a key in the Keychain and a
/// host record, none of which a UI test can create through the interface without a
/// server to point at.
///
/// The key arrives as PEM text in the environment rather than as a path, so the same
/// mechanism works on a device, where the host's filesystem is not visible.
enum UITestSeeding {
    struct Seed {
        let host: Host
        let privateKeyPEM: String
        let keyID: UUID
        /// The harness's screen server, reached through the seeded connection (D-027).
        let screen: ScreenConnection?
        /// A connection that attaches to tmux, when the harness started a server with
        /// tmux on it (D-059). Its own host and password: the machine running the tests
        /// has no tmux, so this one is a container.
        let tmuxHost: Host?
        let tmuxPassword: String?
    }

    static var seedFromEnvironment: Seed? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ST_UITEST_SEED"] == "1",
              let hostname = environment["ST_UITEST_HOST"],
              let portString = environment["ST_UITEST_PORT"], let port = Int(portString),
              let username = environment["ST_UITEST_USER"],
              let pem = environment["ST_UITEST_KEY"], !pem.isEmpty
        else { return nil }

        // Stable across launches, so a relaunch sees the same connection rather than a
        // new one that happens to point at the same server. Anything testing behaviour
        // that spans a launch — reopening the sessions from last time — depends on it.
        let keyID = UUID(uuidString: "00000000-0000-4000-A000-000000000001")!
        return Seed(
            host: Host(
                id: UUID(uuidString: "00000000-0000-4000-A000-000000000002")!,
                name: environment["ST_UITEST_NAME"] ?? "Test Server",
                hostname: hostname,
                port: port,
                username: username,
                transport: .directTCP,
                credentials: [.privateKey(id: keyID)],
                // A forwarding rule, for the run that drives the port-forward screen
                // (D-045). Its destination is the test server's own SSH port, which is
                // the one address the harness can promise is listening.
                portForwards: environment["ST_UITEST_FORWARD_PORT"].flatMap { Int($0) }.map { listenPort in
                    [PortForward(
                        id: UUID(uuidString: "00000000-0000-4000-A000-000000000004")!,
                        name: environment["ST_UITEST_FORWARD_NAME"] ?? "Seeded forward",
                        kind: .local,
                        listenPort: listenPort,
                        targetHost: "127.0.0.1",
                        targetPort: port
                    )]
                }
            ),
            privateKeyPEM: pem,
            keyID: keyID,
            screen: environment["ST_UITEST_VNC_PORT"].flatMap { Int($0) }.map { port in
                ScreenConnection(
                    id: UUID(uuidString: "00000000-0000-4000-A000-000000000003")!,
                    // Named by the run where one is given. A capture for the store cannot
                    // show a row called "Test Screen"; every other run keeps the default.
                    name: environment["ST_UITEST_SCREEN_NAME"] ?? "Test Screen",
                    address: "127.0.0.1",
                    port: port,
                    route: .throughSSH(hostID: UUID(uuidString: "00000000-0000-4000-A000-000000000002")!)
                )
            },
            tmuxHost: environment["ST_UITEST_TMUX_PORT"].flatMap { Int($0) }.map { port in
                Host(
                    id: UUID(uuidString: "00000000-0000-4000-A000-000000000005")!,
                    name: environment["ST_UITEST_TMUX_NAME"] ?? "tmux Test Server",
                    hostname: environment["ST_UITEST_TMUX_HOST"] ?? "127.0.0.1",
                    port: port,
                    username: environment["ST_UITEST_TMUX_USER"] ?? "tmuxtest",
                    transport: .directTCP,
                    credentials: [.password],
                    usesTmux: true,
                    tmuxSessionName: "uitest"
                )
            },
            tmuxPassword: environment["ST_UITEST_TMUX_PASSWORD"]
        )
    }

    /// Extra connections for a run that needs a populated list rather than one row —
    /// the App Store capture run (`Marketing/AppStore/scripts/capture.sh`).
    ///
    /// Each entry must name a server the harness actually started, because every one of
    /// them is opened for real during that run. The value is a JSON array of
    /// `{"name", "hostname", "port", "username"}`; they share the seeded key, since the
    /// harness authorises the same public key on every fixture.
    static var extraHostsFromEnvironment: [Host] {
        guard let json = ProcessInfo.processInfo.environment["ST_UITEST_HOSTS"],
              let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([ExtraHost].self, from: data)
        else { return [] }
        let keyID = UUID(uuidString: "00000000-0000-4000-A000-000000000001")!
        return entries.enumerated().map { index, entry in
            Host(
                // Deterministic, so a relaunch finds the same connections rather than
                // duplicates of them.
                id: UUID(uuidString: String(format: "00000000-0000-4000-A000-0000000001%02X", index))!,
                name: entry.name,
                hostname: entry.hostname,
                port: entry.port,
                username: entry.username,
                transport: .directTCP,
                credentials: [.privateKey(id: keyID)]
            )
        }
    }

    private struct ExtraHost: Decodable {
        let name: String
        let hostname: String
        let port: Int
        let username: String
    }

    /// Applies the seed, replacing anything already stored so runs are repeatable.
    /// A run that asks for a reset, with or without an SSH seed. Preferences, snippets,
    /// hosts and the accepted-terms version all outlive the app, so a run that changes
    /// one would otherwise decide the outcome of the next.
    static var resetsState: Bool {
        let environment = ProcessInfo.processInfo.environment
        // A test that relaunches the app to see what survives a launch says so.
        guard environment["ST_UITEST_KEEP_STATE"] != "1" else { return false }
        return environment["ST_UITEST_RESET"] == "1" || seedFromEnvironment != nil
    }

    @MainActor
    static func apply(to container: AppContainer) {
        guard resetsState else { return }
        container.settings.resetToDefaults()
        // Every run would otherwise start behind the consent screen. A run that tests
        // that screen asks for it.
        if ProcessInfo.processInfo.environment["ST_UITEST_SHOW_CONSENT"] != "1" {
            container.settings.acceptedTermsVersion = LegalDocument.currentVersion
        }
        // And past the tour, unless the run is the one that tests it (D-033).
        if ProcessInfo.processInfo.environment["ST_UITEST_SHOW_TUTORIAL"] != "1" {
            container.settings.hasSeenTutorial = true
        }
        container.snippetStore.removeAll()
        container.hostStore.removeAll()
        container.screenStore.removeAll()
        // The wallpaper's record *and* its files: a preference cleared without the pixels leaves
        // a picture nothing points at, and files kept without the preference leave one run's
        // photograph deciding the next run's appearance (D-077).
        container.settings.backdrop = nil
        container.backdrops.removeAll()
        // Sessions left open by the previous run would otherwise be offered for reopening
        // at the top of the list. A run that tests that offer across its own relaunch
        // asks to keep it.
        if ProcessInfo.processInfo.environment["ST_UITEST_KEEP_RESTORATION"] != "1" {
            container.restoration.clear()
        }
        // The terminal theme a capture run asks for. Nothing more than the preference the
        // Appearance settings write, set before the first screen is drawn so a run does
        // not photograph the change happening.
        if let theme = ProcessInfo.processInfo.environment["ST_UITEST_TERMINAL_THEME"] {
            container.settings.followSystemAppearance = false
            container.settings.themeID = theme
        }
        try? container.vault.deleteEverything()
        guard let seed = seedFromEnvironment else { return }
        try? container.vault.storePrivateKey(seed.privateKeyPEM, id: seed.keyID, requireBiometrics: false)
        container.hostStore.add(seed.host)
        for host in extraHostsFromEnvironment { container.hostStore.add(host) }
        if let screen = seed.screen { container.screenStore.add(screen) }
        if let tmuxHost = seed.tmuxHost {
            if let password = seed.tmuxPassword {
                try? container.vault.storePassword(password, hostID: tmuxHost.id)
            }
            container.hostStore.add(tmuxHost)
        }
    }

    /// A link for a UI run to deliver at launch (D-061).
    ///
    /// XCUITest cannot hand an app a URL without driving Safari, and what needs testing is
    /// what the *app* does with one — the question it asks, and that nothing runs before
    /// the answer. The system's part, routing `ssh://` and `apexterminal://` here at all,
    /// is the declaration in `Config/Info.plist`.
    static var linkFromEnvironment: URL? {
        #if DEBUG
        guard let text = ProcessInfo.processInfo.environment["ST_UITEST_OPEN_URL"], !text.isEmpty else {
            return nil
        }
        return URL(string: text)
        #else
        return nil
        #endif
    }

    /// Whether host keys should be trusted without asking, so a UI run is not blocked by
    /// a sheet it cannot meaningfully answer.
    static var trustsHostKeysAutomatically: Bool {
        ProcessInfo.processInfo.environment["ST_UITEST_TRUST_HOST_KEYS"] == "1"
    }
}
#endif
