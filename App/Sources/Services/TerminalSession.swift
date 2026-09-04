import Foundation
import NIOTransportServices
import Observation
import STCloudflare
import STCore
import STSSH
import STTerminal
import UIKit

/// One live terminal.
///
/// Owns the SSH connection, the shell channel and the emulator, and is the only thing
/// that mutates them. Views observe it; nothing else drives it.
@Observable
@MainActor
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case idle
        /// A human-readable step, so "Connecting…" can say *what* it is doing — resolving
        /// Access, opening the tunnel, exchanging keys — which is the difference between a
        /// hang and progress.
        case connecting(step: String)
        /// Waiting for the user to answer a host key or Cloudflare prompt.
        case awaitingUser(prompt: PendingPrompt)
        case connected
        case disconnected(reason: String?)
        case failed(STError)
    }

    enum PendingPrompt: Equatable, Sendable {
        case unknownHostKey(identity: KnownHostIdentity, key: SSHHostKey)
        case changedHostKey(identity: KnownHostIdentity, expected: SSHHostKey, presented: SSHHostKey)
        case password(username: String, host: String)
        case keyPassphrase(keyName: String)
    }

    let id = UUID()
    let host: Host

    private(set) var state: State = .idle
    /// The rendered screen. Replaced wholesale on each update so the view has a single,
    /// consistent snapshot rather than a grid mutating underneath it.
    private(set) var screen: TerminalScreen
    private(set) var modes = TerminalModes()
    private(set) var title: String = ""
    private(set) var size = TerminalSize.default
    /// How far the user has scrolled back, in rows.
    var scrollbackOffset = 0
    /// The current selection, in absolute buffer coordinates.
    var selection: TerminalRange?
    /// Whether the on-screen Control key is armed for the next character typed.
    var controlLatched = false
    /// Search state for the find bar.
    private(set) var searchMatches: [TerminalSearchMatch] = []
    private(set) var focusedMatchIndex: Int?
    /// Text waiting on the user's confirmation before being pasted.
    var pendingPaste: PendingPaste?

    /// A paste the user must confirm.
    ///
    /// Multi-line pasted text is the classic way to run a command you did not mean to:
    /// the newline executes it the instant it arrives. Bracketed paste protects modern
    /// shells, but not every remote program supports it, so the confirmation exists for
    /// the cases where the terminal cannot know.
    struct PendingPaste: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var lineCount: Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }
        var isBracketed: Bool
    }

    private var emulator: TerminalEmulator
    private var connection: SSHConnection?
    private var shell: SSHShellSession?
    private var pumpTask: Task<Void, Never>?
    private let group: NIOTSEventLoopGroup
    private let vault: CredentialVault
    private let knownHosts: any KnownHostsStore
    private let settings: AppSettings
    private let log: STLogger
    private let promptCoordinator: PromptCoordinator

    init(
        host: Host,
        group: NIOTSEventLoopGroup,
        vault: CredentialVault,
        knownHosts: any KnownHostsStore,
        settings: AppSettings,
        log: STLogger
    ) {
        self.host = host
        self.group = group
        self.vault = vault
        self.knownHosts = knownHosts
        self.settings = settings
        self.log = log.child(subsystem: "session")
        promptCoordinator = PromptCoordinator()
        let initialEmulator = TerminalEmulator(
            columns: TerminalSize.default.columns,
            rows: TerminalSize.default.rows,
            scrollbackLimit: settings.scrollbackLimit
        )
        emulator = initialEmulator
        screen = initialEmulator.activeScreen

        // Prompts are raised from the connection's own task, which is not on the main
        // actor; routing them through here is what lets a sheet appear while the
        // connection stays suspended waiting for the answer.
        Task { [weak self, promptCoordinator] in
            await promptCoordinator.setPromptHandler { prompt in
                Task { @MainActor in self?.state = .awaitingUser(prompt: prompt) }
            }
        }
    }

    var displayName: String { title.isEmpty ? host.name : title }

    var isConnected: Bool { if case .connected = state { return true }; return false }

    // MARK: - Lifecycle

    func connect() async {
        guard !isConnected else { return }
        state = .connecting(step: "Resolving \(host.hostname)")

        do {
            let transport = try await makeTransport()
            state = .connecting(step: "Exchanging keys")

            let approval: any HostKeyApprovalDelegate = Self.automaticHostKeyTrust
                ? TrustOnFirstUseApproval()
                : promptCoordinator
            let verifier = HostKeyVerifier(
                identity: host.knownHostIdentity,
                store: knownHosts,
                approval: approval,
                log: log
            )
            let credentials = try await resolveCredentials()

            let connection = try await SSHConnection.connect(
                transport: transport,
                configuration: SSHConnectionConfiguration(
                    username: host.username,
                    credentials: credentials,
                    knownHostIdentity: host.knownHostIdentity
                ),
                hostKeyVerifier: verifier,
                eventLoop: group.next(),
                log: log
            )
            self.connection = connection

            state = .connecting(step: "Starting shell")
            let shell = try await connection.openShell(
                terminalType: host.terminalType,
                size: size,
                environment: host.environment
            )
            self.shell = shell
            startPump(shell: shell, connection: connection)
            state = .connected
            log.info("session connected", ["host": Redactor.hostname(host.hostname)])
        } catch let error as STError {
            state = .failed(error)
            log.error("session failed", ["category": error.category.rawValue])
        } catch {
            state = .failed(STError(
                category: .internalError,
                message: "The connection could not be established.",
                underlyingDescription: String(describing: error)
            ))
        }
    }

    func disconnect() async {
        pumpTask?.cancel()
        pumpTask = nil
        if let shell { await shell.close() }
        if let connection { await connection.close() }
        shell = nil
        connection = nil
        if case .connected = state {
            state = .disconnected(reason: nil)
        }
    }

    /// Reconnects after a drop, reusing the same host and a fresh screen.
    func reconnect() async {
        await disconnect()
        emulator = TerminalEmulator(
            columns: size.columns,
            rows: size.rows,
            scrollbackLimit: settings.scrollbackLimit
        )
        screen = emulator.activeScreen
        scrollbackOffset = 0
        await connect()
    }

    // MARK: - Input and output

    func send(_ text: String) async {
        await send(Data(text.utf8))
    }

    func send(_ data: Data) async {
        guard let shell else { return }
        do {
            try await shell.send(data)
            scrollbackOffset = 0
        } catch let error as STError {
            state = .failed(error)
        } catch {
            log.warning("write failed")
        }
    }

    /// Offers text for pasting, asking first when that is the safer thing to do.
    func requestPaste(_ text: String, confirmMultiline: Bool) async {
        guard shell != nil else { return }
        switch PastePolicy.decide(
            text: text,
            confirmMultiline: confirmMultiline,
            bracketedPaste: modes.bracketedPaste
        ) {
        case .ignore:
            return
        case .confirm:
            pendingPaste = PendingPaste(text: text, isBracketed: modes.bracketedPaste)
        case .send:
            await paste(text)
        }
    }

    /// Sends pasted text, wrapping it in bracketed-paste markers when the remote program
    /// asked for them.
    ///
    /// Bracketed paste is a safety feature, not a formatting one: it is what lets a shell
    /// tell pasted text from typed text and refuse to execute a pasted newline.
    func paste(_ text: String) async {
        guard shell != nil else { return }
        pendingPaste = nil
        if modes.bracketedPaste {
            await send("\u{1B}[200~" + text + "\u{1B}[201~")
        } else {
            await send(text)
        }
    }

    func cancelPendingPaste() { pendingPaste = nil }

    // MARK: - Selection and search

    /// The selected text, ready for the pasteboard.
    var selectedText: String? {
        guard let selection else { return nil }
        let text = screen.text(in: selection)
        return text.isEmpty ? nil : text
    }

    func search(for query: String, caseSensitive: Bool) {
        guard !query.isEmpty else {
            clearSearch()
            return
        }
        searchMatches = screen.search(for: query, caseSensitive: caseSensitive)
        // Start at the most recent match: when someone searches a terminal they are
        // almost always looking for the latest occurrence, not the first.
        focusedMatchIndex = searchMatches.isEmpty ? nil : searchMatches.count - 1
        scrollToFocusedMatch()
    }

    func clearSearch() {
        searchMatches = []
        focusedMatchIndex = nil
    }

    func focusNextMatch(reverse: Bool = false) {
        guard !searchMatches.isEmpty else { return }
        let current = focusedMatchIndex ?? 0
        let next = reverse
            ? (current - 1 + searchMatches.count) % searchMatches.count
            : (current + 1) % searchMatches.count
        focusedMatchIndex = next
        scrollToFocusedMatch()
    }

    var focusedMatch: TerminalRange? {
        guard let focusedMatchIndex, searchMatches.indices.contains(focusedMatchIndex) else { return nil }
        return searchMatches[focusedMatchIndex].range
    }

    private func scrollToFocusedMatch() {
        guard let match = focusedMatch else { return }
        let historyCount = screen.scrollback.count
        // Rows at or below `historyCount` are already on screen.
        if match.start.row >= historyCount {
            scrollbackOffset = 0
            return
        }
        // Put the match a third of the way down, so there is context above and below it.
        let desired = historyCount - match.start.row + (size.rows / 3)
        scrollbackOffset = min(max(0, desired), historyCount)
    }

    func resize(columns: Int, rows: Int) async {
        let newSize = TerminalSize(columns: columns, rows: rows)
        guard newSize != size else { return }
        size = newSize
        emulator.resize(columns: columns, rows: rows)
        screen = emulator.activeScreen
        try? await shell?.resize(to: newSize)
    }

    func scrollBack(by rows: Int) {
        let maximum = screen.scrollback.count
        scrollbackOffset = min(max(0, scrollbackOffset + rows), maximum)
    }

    func scrollToBottom() { scrollbackOffset = 0 }

    /// Answers a prompt the connection is waiting on.
    func resolvePrompt(_ decision: PromptCoordinator.Decision) {
        let coordinator = promptCoordinator
        Task { await coordinator.resolve(decision) }
        if case .awaitingUser = state { state = .connecting(step: "Continuing") }
    }

    // MARK: - Internals

    private func startPump(shell: SSHShellSession, connection: SSHConnection) {
        let output = shell.output
        pumpTask = Task { [weak self] in
            for await event in output {
                guard let self else { return }
                switch event {
                case let .output(data), let .errorOutput(data):
                    await self.consume(data)
                case .exit:
                    continue
                case .closed:
                    await self.handleClosed()
                    return
                }
            }
        }
    }

    private func consume(_ data: Data) async {
        var responses: [Data] = []
        for event in emulator.feed(data) {
            switch event {
            case let .respond(bytes):
                responses.append(bytes)
            case let .title(newTitle):
                title = newTitle
            case .bell:
                if settings.bellEnabled {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            case let .modesChanged(newModes):
                modes = newModes
            case let .alternateScreenChanged(isAlternate):
                // Scrollback is meaningless in a full-screen program's buffer, so any
                // scrolled-back position is abandoned when one takes over.
                if isAlternate { scrollbackOffset = 0 }
            }
        }
        _ = emulator.flush()
        screen = emulator.activeScreen

        // Programs that query the terminal block until it answers.
        for response in responses {
            try? await shell?.send(response)
        }
    }

    private func handleClosed() async {
        pumpTask = nil
        shell = nil
        connection = nil
        if case .failed = state { return }
        state = .disconnected(reason: "The remote host closed the connection.")
    }

    private func makeTransport() async throws -> any ByteStreamTransport {
        switch host.transport {
        case .directTCP:
            return DirectTCPTransport(
                endpoint: TransportEndpoint(host: host.hostname, port: host.port),
                log: log
            )
        case let .cloudflare(jumpDestination):
            state = .connecting(step: "Checking Cloudflare Access")
            let credential = try await resolveAccessCredential()
            return CloudflareCarrierTransport(
                configuration: .init(
                    host: host.hostname,
                    jumpDestination: jumpDestination,
                    userAgent: Self.userAgent
                ),
                credential: credential,
                log: log
            )
        }
    }

    private func resolveAccessCredential() async throws -> AccessCredential {
        let http = URLSessionHTTPTransport(userAgent: Self.userAgent)
        let jwks = JWKSProvider(http: http)
        let discovery = AccessDiscovery(http: http, jwks: jwks, log: log)
        let validator = AccessTokenValidator(jwks: jwks)

        switch try await discovery.probe(host: host.hostname) {
        case .unprotected:
            // A tunnel without an Access policy is a legitimate configuration; the
            // carrier still works, there is just nothing to authenticate.
            return .none

        case let .protected(appInfo):
            if let stored = try? vault.loadAccessToken(appIdentifier: appInfo.storageIdentifier),
               let validated = try? await validator.validate(rawToken: stored, appInfo: appInfo),
               !validated.isExpired() {
                return .userToken(validated)
            }
            state = .connecting(step: "Signing in to Cloudflare Access")
            let login = AccessLoginService(
                http: http,
                presenter: WebAuthenticationPresenter(),
                validator: validator,
                log: log
            )
            let result = try await login.login(appInfo: appInfo, originHost: host.hostname)
            try? vault.storeAccessToken(
                result.token.token.reveal(),
                appIdentifier: appInfo.storageIdentifier
            )
            return .userToken(result.token)
        }
    }

    private func resolveCredentials() async throws -> [SSHCredential] {
        var credentials: [SSHCredential] = []
        for reference in host.credentials {
            switch reference {
            case let .privateKey(id):
                let pem = try vault.loadPrivateKey(
                    id: id,
                    prompt: "Unlock the key for \(host.name)"
                )
                let inspection = try OpenSSHPrivateKeyParser.inspect(pem: pem)
                if inspection.isEncrypted {
                    let passphrase = try await promptCoordinator.requestPassphrase(keyName: host.name)
                    credentials.append(.privateKey(
                        try OpenSSHPrivateKeyParser.parse(pem: pem, passphrase: passphrase)
                    ))
                } else {
                    credentials.append(.privateKey(try OpenSSHPrivateKeyParser.parse(pem: pem)))
                }
            case .password:
                if let stored = try vault.loadPassword(hostID: host.id) {
                    credentials.append(.password(Redacted(stored, label: "ssh-password")))
                } else {
                    let password = try await promptCoordinator.requestPassword(
                        username: host.username,
                        host: host.hostname
                    )
                    credentials.append(.password(Redacted(password, label: "ssh-password")))
                }
            case .none:
                credentials.append(.none)
            }
        }
        return credentials
    }

    static let userAgent = "SuperTerminal/\(Bundle.main.shortVersion) (iOS)"

    /// Whether to accept a first-seen host key without asking.
    ///
    /// Only ever true in a Debug build driven by an automated UI run, where a modal sheet
    /// would block the very screen the run exists to exercise. A release build has no code
    /// path that sets it, so a real user is always asked.
    private static var automaticHostKeyTrust: Bool {
        #if DEBUG
        UITestSeeding.trustsHostKeysAutomatically
        #else
        false
        #endif
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
