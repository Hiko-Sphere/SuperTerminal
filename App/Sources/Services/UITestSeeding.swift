import Foundation
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
                // The harness's screen server, reached through the SSH connection (D-022).
                vnc: environment["ST_UITEST_VNC_PORT"].flatMap { Int($0) }.map { Host.VNCSettings(port: $0, viaSSH: true) }
            ),
            privateKeyPEM: pem,
            keyID: keyID
        )
    }

    /// Applies the seed, replacing anything already stored so runs are repeatable.
    /// A run that asks for a reset, with or without an SSH seed. Preferences, snippets,
    /// hosts and the accepted-terms version all outlive the app, so a run that changes
    /// one would otherwise decide the outcome of the next.
    static var resetsState: Bool {
        ProcessInfo.processInfo.environment["ST_UITEST_RESET"] == "1" || seedFromEnvironment != nil
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
        container.snippetStore.removeAll()
        container.hostStore.removeAll()
        // The "reopen last time's sessions" offer would otherwise carry over from the
        // previous run and sit above the connection list, wearing the same server name.
        container.restoration.clear()
        try? container.vault.deleteEverything()
        guard let seed = seedFromEnvironment else { return }
        try? container.vault.storePrivateKey(seed.privateKeyPEM, id: seed.keyID, requireBiometrics: false)
        container.hostStore.add(seed.host)
    }

    /// Whether host keys should be trusted without asking, so a UI run is not blocked by
    /// a sheet it cannot meaningfully answer.
    static var trustsHostKeysAutomatically: Bool {
        ProcessInfo.processInfo.environment["ST_UITEST_TRUST_HOST_KEYS"] == "1"
    }
}
#endif
