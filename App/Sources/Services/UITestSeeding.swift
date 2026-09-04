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

        let keyID = UUID()
        return Seed(
            host: Host(
                name: environment["ST_UITEST_NAME"] ?? "Test Server",
                hostname: hostname,
                port: port,
                username: username,
                transport: .directTCP,
                credentials: [.privateKey(id: keyID)]
            ),
            privateKeyPEM: pem,
            keyID: keyID
        )
    }

    /// Applies the seed, replacing anything already stored so runs are repeatable.
    @MainActor
    static func apply(to container: AppContainer) {
        guard let seed = seedFromEnvironment else { return }
        // Preferences and snippets outlive the app, so a run that changes one would
        // otherwise decide the outcome of the next.
        container.settings.resetToDefaults()
        container.snippetStore.removeAll()
        container.hostStore.removeAll()
        try? container.vault.deleteEverything()
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
