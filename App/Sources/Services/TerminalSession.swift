import Foundation
import NIOTransportServices
import Observation
import STCloudflare
import STCore
import STForwarding
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
        /// The connection was saved without a user name (D-024).
        case username(host: String)
        /// The server is asking its own questions, keyboard-interactive (D-051). One
        /// round; a server may send several, and each raises this again.
        case keyboardInteractive(host: String, challenge: SSHKeyboardInteractiveChallenge)
    }

    let id = UUID()
    let host: Host

    private(set) var state: State = .idle

    /// What automatic reconnection is doing, if anything. `nil` means it is not running.
    private(set) var reconnection: Reconnection?

    /// A connection that is being retried without the user asking.
    ///
    /// Shown rather than hidden: a terminal that silently reconnects has handed the user a
    /// *new* shell with none of the state the old one had — a different working directory,
    /// no running program, no environment they set — and letting that pass unremarked is
    /// how someone runs a command in the wrong place.
    struct Reconnection: Equatable, Sendable {
        var attempt: Int
        var nextAttempt: Date?
        var isAttempting: Bool
        var lastError: STError
        /// Set when the network is gone: waiting for it to return rather than counting
        /// attempts down, because attempts spent offline teach nothing and giving up
        /// while still in a tunnel is exactly the wrong moment to stop.
        var isWaitingForNetwork: Bool
    }

    private let reachability: NetworkReachability?
    private let haptics: Haptics?
    private var reconnectionTask: Task<Void, Never>?
    /// Whether the shell reported an exit status before the channel closed. A shell that
    /// exited is a session the user ended; a channel that closed without one is a drop.
    private var shellExited = false
    /// Whether the user has already been told that what they type is going nowhere.
    private var hasSaidInputIsGoingNowhere = false
    /// The rendered screen. Replaced wholesale on each update so the view has a single,
    /// consistent snapshot rather than a grid mutating underneath it.
    private(set) var screen: TerminalScreen
    private(set) var modes = TerminalModes()
    private(set) var hyperlinks: [Int: TerminalHyperlink] = [:]
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
    /// A hyperlink the user tapped, awaiting confirmation before it is opened.
    ///
    /// Never opened straight away: the URL comes from the remote host, and a terminal
    /// that opens whatever a server puts on the screen is a phishing vector. The user
    /// sees the destination first.
    var pendingLink: TerminalHyperlink?

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

    /// Where the shell says it is, from OSC 7 (D-062). Empty until a shell says.
    private(set) var workingDirectory = ""
    /// Whether this session's shell speaks OSC 133 — set the first time it does.
    ///
    /// Worth knowing rather than assuming: it is what separates an exact record of what
    /// was run from a heuristic reading of the screen.
    private(set) var shellIntegration = false
    /// What the last command exited with, when the shell said (OSC 133 `D`).
    private(set) var lastExitCode: Int?
    /// So the refusal is said once per session rather than after every yank.
    private var hasRefusedAClipboardWrite = false
    private var emulator: TerminalEmulator
    private var connection: SSHConnection?
    /// Gives the transport back rather than closing it (D-054). A connection shared with
    /// two other tabs is not this session's to close; the pool decides when it goes.
    private var releaseConnection: (@Sendable () async -> Void)?
    /// The port forwards running on this connection (D-045), and what each is doing.
    ///
    /// It lives on the session rather than on the host because that is the truth: a
    /// forward is a thing this connection is doing, and it stops existing when the
    /// connection does. The rules are saved on the host; the running of them is here.
    private var forwarding: ForwardingSession?
    private(set) var forwardStates: [PortForward.ID: PortForwardSnapshot] = [:]
    private var shell: SSHShellSession?
    private var pumpTask: Task<Void, Never>?
    private let group: NIOTSEventLoopGroup
    private let vault: CredentialVault
    private let knownHosts: any KnownHostsStore
    private let settings: AppSettings
    private let log: STLogger
    private let promptCoordinator: PromptCoordinator
    /// Transport, Access, host key and credentials — shared with remote screens (D-022).
    private let connector: HostConnector

    init(
        host: Host,
        group: NIOTSEventLoopGroup,
        vault: CredentialVault,
        knownHosts: any KnownHostsStore,
        settings: AppSettings,
        log: STLogger,
        reachability: NetworkReachability? = nil,
        haptics: Haptics? = nil,
        keyRecord: @escaping @Sendable (UUID) -> StoredKey? = { _ in nil },
        certificateAuthorities: [SSHCertificateAuthority] = [],
        hostByID: @escaping @Sendable (UUID) -> Host? = { _ in nil },
        pool: SSHConnectionPool? = nil
    ) {
        self.host = host
        self.group = group
        self.vault = vault
        self.knownHosts = knownHosts
        self.settings = settings
        self.reachability = reachability
        self.haptics = haptics
        let sessionLog = log.child(subsystem: "session")
        self.log = sessionLog
        let prompts = PromptCoordinator()
        promptCoordinator = prompts
        connector = HostConnector(
            host: host, group: group, vault: vault, knownHosts: knownHosts,
            log: sessionLog, prompts: prompts,
            keyRecord: keyRecord,
            certificateAuthorities: certificateAuthorities,
            hostByID: hostByID,
            pool: pool
        )
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

    /// The last command the user ran, kept after the history recorder has drained the
    /// list, so the assistant can say what it is explaining (D-020).
    private(set) var lastSubmittedCommand: String?

    /// The visible screen as text, for the assistant's "last screen" choice. The user
    /// sees exactly this before it is sent.
    var screenText: String { screen.lines.map(\.text).joined(separator: "\n") }

    /// Puts a suggested command on the prompt without running it — a single line, so
    /// nothing is submitted; the user reads it, then presses Return or not.
    func insert(commandText: String) async {
        guard shell != nil else { return }
        let singleLine = commandText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard !singleLine.isEmpty else { return }
        await insertText(singleLine)
    }

    /// Asks the server what it is, on a channel of its own, after the shell is already
    /// serving the user. `uname -s` answers on every POSIX system; when it cannot run —
    /// Windows OpenSSH has no `uname` — `cmd /c ver` is asked instead. Nothing is typed
    /// into the user's shell, and a server that answers with nothing usable leaves the
    /// record as it was.
    private func detectPlatform(over connection: SSHConnection) {
        Task { [weak self] in
            var uname: String?
            var version: String?
            if let result = try? await connection.execute(command: HostPlatform.unameCommand, timeout: .seconds(10)),
               result.exitStatus == 0 {
                uname = result.standardOutputText
            }
            if HostPlatform.detect(unameOutput: uname, windowsVersionOutput: nil) == nil,
               let result = try? await connection.execute(command: HostPlatform.windowsVersionCommand, timeout: .seconds(10)),
               result.exitStatus == 0 {
                version = result.standardOutputText
            }
            guard let platform = HostPlatform.detect(unameOutput: uname, windowsVersionOutput: version) else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.detectedPlatform = platform
                self.log.info("server platform detected", ["platform": platform.rawValue])
                self.onPlatformDetected?(platform)
            }
        }
    }

    var isConnected: Bool { if case .connected = state { return true }; return false }
    /// Called once per successful handshake, on the main actor.
    var onConnected: (() -> Void)?
    /// Called on the main actor with what the server reported about its platform (D-019).
    var onPlatformDetected: ((HostPlatform) -> Void)?
    /// What detection found for this session, kept so the terminal can show it.
    private(set) var detectedPlatform: HostPlatform?

    // MARK: - Lifecycle

    func connect() async {
        guard !isConnected else { return }
        // Installed here as well as at init, and awaited: the task at init usually wins,
        // but "usually" is not a guarantee, and a host-key question raised before the
        // handler exists waits for an answer that can never arrive (D-059).
        await promptCoordinator.setPromptHandler { [weak self] prompt in
            Task { @MainActor in self?.state = .awaitingUser(prompt: prompt) }
        }
        state = .connecting(step: String(localized: "Resolving \(host.hostname)"))

        do {
            let established = try await connector.establish { [weak self] step in
                self?.state = .connecting(step: step)
            }
            let connection = established.connection
            self.connection = connection
            releaseConnection = established.release

            state = .connecting(step: String(localized: "Starting shell"))
            let shell = try await connection.openShell(
                terminalType: host.terminalType,
                size: size,
                environment: host.environment
            )
            self.shell = shell
            startPump(shell: shell, connection: connection)
            await startForwards(on: connection)
            state = .connected
            onConnected?()
            haptics?.play(.connected)
            log.info("session connected", ["host": Redactor.hostname(host.hostname)])
            detectPlatform(over: connection)
        } catch let error as STError {
            state = .failed(error)
            log.error("session failed", ["category": error.category.rawValue])
        } catch {
            state = .failed(STError(
                category: .internalError,
                message: String(localized: "The connection could not be established."),
                underlyingDescription: String(describing: error)
            ))
        }
    }

    func disconnect() async {
        pumpTask?.cancel()
        pumpTask = nil
        await stopForwards()
        if let shell { await shell.close() }
        // The shell channel is this session's and is closed; the transport underneath it
        // may not be, so it is handed back instead.
        await releaseConnection?()
        releaseConnection = nil
        shell = nil
        connection = nil
        if case .connected = state {
            state = .disconnected(reason: nil)
        }
    }

    /// Reconnects after a drop, keeping everything already on screen.
    ///
    /// The scrollback is the reason the user is looking: it holds the command that was
    /// running when the connection went, and what it had printed. Clearing it to make the
    /// reconnection look tidy throws away the only record of what happened.
    ///
    /// A rule is drawn where the break was, labelled with the app's own name so it cannot
    /// be mistaken for something the server said. The shell on the other side is a new
    /// one — a different working directory, nothing running, none of the environment the
    /// user had set — and that is worth marking plainly.
    func reconnect() async {
        await disconnect()
        shellExited = false
        annotate(String(localized: "Reconnecting…"))
        scrollbackOffset = 0
        await connect()
        if case .connected = state {
            annotate(String(localized: "Reconnected. This is a new shell."))
        }
    }

    /// Writes a line of the app's own into the buffer, styled so it reads as an aside.
    private func annotate(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        // Dim, and prefixed with the app's name, so it is never read as server output.
        let line = "\r\n\u{1B}[2m── Apex Terminal: \(message) \(time) ──\u{1B}[0m\r\n"
        for event in emulator.feed(Data(line.utf8)) {
            if case let .title(newTitle) = event { title = newTitle }
        }
        _ = emulator.flush()
        screen = emulator.activeScreen
    }

    // MARK: - Input and output

    func send(_ text: String) async {
        await send(Data(text.utf8))
    }

    /// Sends once the shell is there, or gives up saying so.
    ///
    /// A session opened from a link (D-061) has not connected yet when the command to run
    /// arrives; sending into it would drop the bytes, and a command that silently did not
    /// run is worse than one that visibly did not.
    func sendWhenConnected(_ text: String, timeout: Duration = .seconds(45)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if shell != nil { await send(text); return }
            if case .failed = state { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        annotate(String(localized: "The command from the link was not sent: the session did not connect."))
    }

    /// Inserts a snippet once the shell is there (D-061).
    ///
    /// A session opened by a shortcut has not connected when the snippet arrives, and
    /// sending into it would drop the text — a shortcut that silently did nothing is worse
    /// than one that visibly failed.
    func insertWhenConnected(snippet: Snippet, timeout: Duration = .seconds(45)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if shell != nil { await insert(snippet: snippet); return }
            if case .failed = state { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        annotate(String(localized: "The snippet was not sent: the session did not connect."))
    }

    /// Inserts a snippet's command, and optionally runs it.
    ///
    /// Multi-line snippets go through bracketed paste when the remote program supports
    /// it, for the same reason a multi-line paste does: without it, each newline runs
    /// what precedes it the moment it arrives.
    func insert(snippet: Snippet) async {
        guard shell != nil else { return }
        await insertText(snippet.command)
        if snippet.runsImmediately {
            noteTypedInput(Data("\r".utf8))
            await send("\r")
        }
    }

    /// Puts literal text on the remote line as if it had been typed.
    ///
    /// Goes through the same accounting as typing, so a snippet or a paste followed by
    /// Return is recorded in history exactly like the same command typed by hand — the
    /// bracketed-paste markers excluded, since they are framing rather than content.
    private func insertText(_ text: String) async {
        let needsBrackets = text.contains(where: \.isNewline) && modes.bracketedPaste
        noteTypedInput(Data(text.utf8))
        if needsBrackets {
            await send("\u{1B}[200~" + text + "\u{1B}[201~")
        } else {
            await send(text)
        }
    }

    /// The last command the user submitted, for the history recorder.
    ///
    /// Tracked here rather than by watching the terminal, because the terminal's echo is
    /// the *shell's* rendering — it includes the prompt, and for a shell with completion
    /// or syntax highlighting it is not the literal text that was typed.
    private var submittedCommands: [String] = []
    /// Whether the pending line still matches what the remote line editor holds.
    private var lineIsTrustworthy = true
    private enum EscapeState { case ground, escape, csi, string, stringEscape }
    private var escapeState: EscapeState = .ground

    /// Buffer of what the user has typed since the last Return.
    private var pendingInput = ""

    /// Notes typed bytes so a submitted command can be recorded.
    func noteTypedInput(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for character in text {
            if escapeState != .ground {
                advanceEscape(character)
                continue
            }
            switch character {
            case "\u{1B}":
                escapeState = .escape
                // An escape sequence mid-line means the shell is editing the line for us
                // — recalling from its own history, or moving the cursor so that what is
                // typed next lands somewhere we cannot see. From here the reconstruction
                // would be a guess, and a wrong command in history is worse than none.
                if !pendingInput.isEmpty { lineIsTrustworthy = false }
            case "\r", "\n":
                let command = pendingInput.trimmingCharacters(in: .whitespaces)
                let trustworthy = lineIsTrustworthy
                pendingInput = ""
                lineIsTrustworthy = true
                // A list, not a single value: one paste can submit several lines, and
                // dropping all but the last would silently lose them.
                if trustworthy, !command.isEmpty {
                    submittedCommands.append(command)
                    lastSubmittedCommand = command
                    for observe in submittedCommandObservers.values { observe(command) }
                }
            case "\u{7F}", "\u{08}":
                if !pendingInput.isEmpty { pendingInput.removeLast() }
            case "\u{03}", "\u{04}", "\u{1A}", "\u{15}":
                // Interrupt, EOF, suspend and kill-line abandon the line rather than
                // submitting it.
                pendingInput = ""
                lineIsTrustworthy = true
            default:
                if character.isLetter || character.isNumber || character.isPunctuation
                    || character.isSymbol || character == " "
                {
                    pendingInput.append(character)
                } else {
                    // Some other control byte — a completion key, a readline binding.
                    // Whatever it does to the line, we did not see it.
                    if !pendingInput.isEmpty { lineIsTrustworthy = false }
                }
            }
        }
    }

    /// Consumes the rest of an escape sequence so its bytes are never mistaken for typing.
    ///
    /// Enough of ECMA-48 to recognise where a sequence ends: CSI and the string-carrying
    /// introducers run until a final byte, everything else is two bytes long.
    private func advanceEscape(_ character: Character) {
        guard let scalar = character.unicodeScalars.first else { return }
        switch escapeState {
        case .ground:
            return
        case .escape:
            switch character {
            case "[": escapeState = .csi
            case "P", "]", "X", "^", "_": escapeState = .string
            default: escapeState = .ground
            }
        case .csi:
            // Parameter and intermediate bytes, then a final byte in 0x40...0x7E.
            if (0x40 ... 0x7E).contains(scalar.value) { escapeState = .ground }
        case .string:
            // ST (ESC \) or BEL terminates; a bare ESC starts the two-byte terminator.
            if scalar.value == 0x07 { escapeState = .ground }
            if character == "\u{1B}" { escapeState = .stringEscape }
        case .stringEscape:
            escapeState = character == "\\" ? .ground : .string
        }
    }

    /// Returns the commands submitted since the last call, and forgets them.
    func takeSubmittedCommands() -> [String] {
        defer { submittedCommands.removeAll() }
        return submittedCommands
    }

    /// Every command submitted from now on, whatever sent it.
    ///
    /// A stream rather than a callback because the recorder is a view that comes and
    /// goes, while the session outlives it.
    var submittedCommandStream: AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            submittedCommandObservers[id] = { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.submittedCommandObservers[id] = nil }
            }
        }
    }

    private var submittedCommandObservers: [UUID: (String) -> Void] = [:]

    func send(_ data: Data) async {
        guard let shell else {
            // Typing into a session with no shell used to vanish without a word, which
            // looks exactly like a broken keyboard — and was reported as one. Said once
            // per disconnection, not once per keystroke.
            if !hasSaidInputIsGoingNowhere {
                hasSaidInputIsGoingNowhere = true
                annotate(String(localized: "Not connected — what you type is not being sent."))
            }
            return
        }
        hasSaidInputIsGoingNowhere = false
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
        await insertText(text)
    }

    func cancelPendingPaste() { pendingPaste = nil }

    /// Sends a pointer event, if the remote program asked to be told about them.
    func reportMouse(_ event: TerminalMouseEvent) async {
        guard let data = MouseReportEncoder.encode(event, modes: modes) else { return }
        await send(data)
    }

    /// The hyperlink on a cell, if it carries one.
    func hyperlink(at position: TerminalPosition) -> TerminalHyperlink? {
        let lines = screen.allLines
        guard lines.indices.contains(position.row) else { return nil }
        let line = lines[position.row]
        guard position.column < line.width else { return nil }
        guard let identifier = line[position.column].attributes.hyperlinkID else { return nil }
        return hyperlinks[identifier]
    }

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

    /// The grid changed size. Pixels as well as cells: RFC 4254's window-change carries both,
    /// and a program that draws pictures — `img2sixel`, `gnuplot`, anything using the Kitty
    /// protocol — reads the pixel fields to know how big a cell is. Sending zeroes, which is
    /// what this did until D-065, makes those programs guess or refuse.
    func resize(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) async {
        let newSize = TerminalSize(
            columns: columns,
            rows: rows,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        guard newSize != size else { return }
        size = newSize
        emulator.resize(columns: columns, rows: rows)
        if pixelWidth > 0, pixelHeight > 0 {
            // The same arithmetic the view did, back the other way: this is what decides how
            // many cells a picture covers.
            emulator.cellSize = TerminalEmulator.CellSize(
                width: max(1, pixelWidth / max(1, columns)),
                height: max(1, pixelHeight / max(1, rows))
            )
        }
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
        if case .awaitingUser = state { state = .connecting(step: String(localized: "Continuing")) }
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
                    // The shell ended on its own; the close that follows is expected.
                    self.noteShellExited()
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
                if settings.bellEnabled { haptics?.play(.bell) }
            case let .modesChanged(newModes):
                modes = newModes
            case let .alternateScreenChanged(isAlternate):
                // Scrollback is meaningless in a full-screen program's buffer, so any
                // scrolled-back position is abandoned when one takes over.
                if isAlternate { scrollbackOffset = 0 }
            case let .workingDirectory(path):
                // Where the shell says it is (D-062). Shown next to the session's name, so
                // three tabs on one server are told apart by what they are doing.
                workingDirectory = path
            case let .clipboardWriteRequested(data):
                handleClipboardRequest(data)
            case let .shellIntegration(mark):
                handle(mark)
            }
        }
        _ = emulator.flush()
        screen = emulator.activeScreen
        hyperlinks = emulator.hyperlinks

        // Programs that query the terminal block until it answers.
        for response in responses {
            try? await shell?.send(response)
        }
    }

    /// A program asked to put something on this device's clipboard — OSC 52 (D-062).
    ///
    /// Off unless the person turned it on, and the first refusal says so rather than
    /// vanishing: a `vim` yank that silently does nothing teaches nothing, and the setting
    /// it needs is two screens away.
    private func handleClipboardRequest(_ data: Data) {
        guard settings.remoteClipboardWrites else {
            guard !hasRefusedAClipboardWrite else { return }
            hasRefusedAClipboardWrite = true
            annotate(String(localized: "A program on this server tried to copy to your clipboard. Settings → Security can allow it."))
            return
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        Clipboard.copy(text, expiringAfter: settings.clipboardExpirySeconds)
        haptics?.play(.textInserted)
    }

    /// OSC 133 (D-062): where the prompt is, what was typed, and how it ended.
    private func handle(_ mark: ShellIntegrationMark) {
        switch mark {
        case .promptStart:
            shellIntegration = true
        case .commandStart:
            shellIntegration = true
        case .outputStart:
            shellIntegration = true
        case let .commandFinished(exitCode):
            shellIntegration = true
            lastExitCode = exitCode
        }
    }

    private func noteShellExited() { shellExited = true }

    // MARK: - Port forwarding (D-045)

    /// Rules the user asked to start with the connection.
    private func startForwards(on connection: SSHConnection) async {
        let rules = host.portForwards ?? []
        guard !rules.isEmpty else { return }
        let session = ForwardingSession(connection: connection, group: group, log: log)
        forwarding = session
        for rule in rules where rule.startsAutomatically {
            _ = await session.start(rule)
        }
        await refreshForwardStates()
    }

    private func stopForwards() async {
        await forwarding?.stopAll()
        forwarding = nil
        forwardStates = [:]
    }

    /// Starts one rule by hand. Returns nothing: what happened is in `forwardStates`,
    /// which is what the interface reads.
    func startForward(_ rule: PortForward) async {
        guard let connection else { return }
        if forwarding == nil {
            forwarding = ForwardingSession(connection: connection, group: group, log: log)
        }
        _ = await forwarding?.start(rule)
        await refreshForwardStates()
    }

    func stopForward(_ id: PortForward.ID) async {
        await forwarding?.stop(id)
        await refreshForwardStates()
    }

    /// Re-reads what every rule is doing. Called after a change, and on a timer while the
    /// forwarding screen is open — traffic counters have no other way to move.
    func refreshForwardStates() async {
        forwardStates = await forwarding?.snapshot() ?? [:]
    }

    private func handleClosed() async {
        pumpTask = nil
        shell = nil
        await releaseConnection?()
        releaseConnection = nil
        connection = nil
        // A forward cannot outlive the connection under it, and must not go on claiming
        // to be running when the thing it runs over has gone.
        await stopForwards()
        if case .failed = state { return }
        if shellExited {
            state = .disconnected(reason: String(localized: "The shell exited."))
            haptics?.play(.disconnected)
            return
        }
        state = .disconnected(reason: String(localized: "The connection to the host was lost."))
        haptics?.play(.disconnected)
        beginAutomaticReconnection(after: STError(
            category: .network,
            message: String(localized: "The connection to the host was lost."),
            recoverySuggestion: String(localized: "Reconnecting.")
        ))
    }

    // MARK: - Automatic reconnection

    /// Starts retrying, if this failure is one a retry can fix and the user wants it.
    func beginAutomaticReconnection(after error: STError) {
        guard settings.automaticReconnect else { return }
        guard ReconnectionPolicy.isWorthRetrying(error.category) else { return }
        guard reconnectionTask == nil else { return }

        let policy = ReconnectionPolicy()
        reconnection = Reconnection(
            attempt: 0,
            nextAttempt: nil,
            isAttempting: false,
            lastError: error,
            isWaitingForNetwork: reachability.map { !$0.isOnline } ?? false
        )
        reconnectionTask = Task { [weak self] in
            await self?.runReconnection(policy: policy)
        }
    }

    /// Stops retrying. The user asked, or they are doing something else with the session.
    func cancelAutomaticReconnection() {
        reconnectionTask?.cancel()
        reconnectionTask = nil
        reconnection = nil
    }

    /// Skips the remaining wait.
    func retryNow() {
        guard reconnection != nil else { return }
        reconnectionTask?.cancel()
        reconnectionTask = nil
        let policy = ReconnectionPolicy()
        reconnection?.nextAttempt = Date()
        reconnectionTask = Task { [weak self] in
            await self?.runReconnection(policy: policy, startingAt: 1, waitFirst: false)
        }
    }

    private func runReconnection(
        policy: ReconnectionPolicy,
        startingAt firstAttempt: Int = 1,
        waitFirst: Bool = true
    ) async {
        var attempt = firstAttempt
        var shouldWait = waitFirst

        while !Task.isCancelled, policy.allowsAttempt(attempt) {
            if let reachability, !reachability.isOnline {
                // Hold rather than spend attempts. Coming out of a tunnel with the
                // retries already exhausted is the one moment this must not happen.
                reconnection?.isWaitingForNetwork = true
                reconnection?.nextAttempt = nil
                await waitForNetwork(reachability)
                guard !Task.isCancelled else { return }
                // A different network is new information, so the count starts again.
                attempt = 1
                shouldWait = false
                reconnection?.isWaitingForNetwork = false
            }

            if shouldWait {
                let delay = policy.delay(forAttempt: attempt)
                reconnection?.nextAttempt = Date().addingTimeInterval(
                    Double(delay.components.seconds) + Double(delay.components.attoseconds) * 1e-18
                )
                reconnection?.attempt = attempt
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            shouldWait = true
            guard !Task.isCancelled else { return }

            reconnection?.attempt = attempt
            reconnection?.isAttempting = true
            reconnection?.nextAttempt = nil
            await reconnect()
            reconnection?.isAttempting = false

            if case .connected = state {
                reconnection = nil
                reconnectionTask = nil
                return
            }
            if case let .failed(error) = state, !ReconnectionPolicy.isWorthRetrying(error.category) {
                // Something a retry cannot fix — a changed host key, a rejected password.
                // Stop and leave the error on screen where the user will see it.
                reconnection = nil
                reconnectionTask = nil
                return
            }
            if case .awaitingUser = state {
                // A prompt is on screen; the user is now driving.
                reconnection = nil
                reconnectionTask = nil
                return
            }
            attempt += 1
        }

        // Out of attempts. The manual button remains, and says so.
        reconnection?.nextAttempt = nil
        reconnection?.isAttempting = false
        reconnectionTask = nil
    }

    private func waitForNetwork(_ reachability: NetworkReachability) async {
        for await _ in reachability.usablePathChanges {
            return
        }
    }

}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
