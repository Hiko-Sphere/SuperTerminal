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
    let snippetStore: SnippetStore
    let sessionManager: SessionManager
    let settings: AppSettings
    let vault: CredentialVault
    let knownHosts: any KnownHostsStore
    let diagnostics: DiagnosticsCentre

    private init(
        hostStore: HostStore,
        snippetStore: SnippetStore,
        sessionManager: SessionManager,
        settings: AppSettings,
        vault: CredentialVault,
        knownHosts: any KnownHostsStore,
        diagnostics: DiagnosticsCentre
    ) {
        self.hostStore = hostStore
        self.snippetStore = snippetStore
        self.sessionManager = sessionManager
        self.settings = settings
        self.vault = vault
        self.knownHosts = knownHosts
        self.diagnostics = diagnostics
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
        let sessionManager = SessionManager(
            vault: vault,
            knownHosts: knownHosts,
            settings: settings,
            diagnostics: diagnostics
        )
        let container = AppContainer(
            hostStore: HostStore(directory: directory),
            snippetStore: SnippetStore(directory: directory, settings: settings),
            sessionManager: sessionManager,
            settings: settings,
            vault: vault,
            knownHosts: knownHosts,
            diagnostics: diagnostics
        )
        #if DEBUG
        UITestSeeding.apply(to: container)
        #endif
        return container
    }
}

/// Collects redacted log records and vends the logger the rest of the app uses.
@MainActor
final class DiagnosticsCentre {
    let buffer = RingBufferLogSink(capacity: 2000)
    let logger: STLogger

    init() {
        logger = STLogger(
            subsystem: "SuperTerminal",
            sinks: [buffer, OSLogSink(subsystem: "dev.superterminal", category: "app")],
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
            "SuperTerminal diagnostics",
            "Generated: \(formatter.string(from: Date()))",
            "",
            "Records are redacted at the point they are written: no commands, terminal",
            "output, hostnames, passwords, keys or tokens are captured.",
            "",
        ]
        for record in buffer.snapshot() {
            lines.append("\(formatter.string(from: record.timestamp)) \(record.rendered)")
        }
        return lines.joined(separator: "\n")
    }
}
