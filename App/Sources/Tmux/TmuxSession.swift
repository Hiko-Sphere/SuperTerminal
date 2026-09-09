import Foundation
import NIOTransportServices
import Observation
import STCore
import STSSH
import STTerminal
import STTmux

/// A tmux session, as the app holds it: one SSH connection, one control-mode client, and
/// whatever windows and panes tmux has behind it.
///
/// Kept apart from ``TerminalSession`` rather than folded into it. A terminal session owns
/// a shell and draws it; a tmux session owns a *server's* idea of several shells and draws
/// what tmux says the arrangement is. Merging them would mean one class with two layouts,
/// two input paths and two notions of what "the terminal" means — and the app already has
/// the shape for this: a remote screen is a third kind of thing shown in the same places,
/// and tmux is the fourth.
@MainActor
@Observable
final class TmuxSession: Identifiable {
    enum State: Equatable {
        case idle
        case connecting(step: String)
        case attached
        case failed(STError)
        case detached(reason: String?)
    }

    let id = UUID()
    let host: Host
    private(set) var state: State = .idle
    /// What tmux has, as of the last thing it said.
    private(set) var windows: [TmuxWorkspace.Window] = []
    /// The terminals for every pane, read together with the windows so a view never draws
    /// a pane whose terminal it cannot find.
    private(set) var snapshot: TmuxWorkspace.Snapshot?
    /// The window being shown. Follows tmux when the current one goes.
    var activeWindowID: TmuxWindowID?

    private let connector: HostConnector
    private let prompts: PromptCoordinator
    private let log: STLogger
    /// What the connection is waiting for the user to answer — a host key it has not seen,
    /// a password, a question the server asked. A tmux session connects the same way a
    /// terminal does, so it has to be able to ask the same things.
    private(set) var pendingPrompt: TerminalSession.PendingPrompt?
    private var connection: SSHConnection?
    private var releaseConnection: (@Sendable () async -> Void)?
    private var shell: SSHShellSession?
    private var workspace: TmuxWorkspace?
    private var pumpTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    /// The size of the view, in cells. tmux sizes its panes to it.
    private var clientSize = (columns: 80, rows: 24)

    init(host: Host, connector: HostConnector, prompts: PromptCoordinator, log: STLogger = .disabled) {
        self.host = host
        self.connector = connector
        self.prompts = prompts
        self.log = log
    }

    /// Answers whatever the connection is waiting on.
    func resolvePrompt(_ decision: PromptCoordinator.Decision) {
        pendingPrompt = nil
        let prompts = prompts
        Task { await prompts.resolve(decision) }
    }

    var activeWindow: TmuxWorkspace.Window? {
        guard let activeWindowID else { return windows.first }
        return windows.first { $0.id == activeWindowID } ?? windows.first
    }

    /// The command that attaches. `-A` means "attach if it exists, create if it does not",
    /// which is what makes the app's connection reusable rather than a new session every
    /// time — the whole reason to run tmux at all.
    ///
    /// `-C` and not `-CC`: the second `C` asks tmux to turn off echo on a terminal, and
    /// there is no terminal here. tmux says so and exits — measured, "tcgetattr failed:
    /// Inappropriate ioctl for device" — so the app opens a command channel with no
    /// pseudo-terminal and speaks the protocol on it.
    private var attachCommand: String {
        let name = host.tmuxSessionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = (name?.isEmpty == false ? name! : "apex")
        return "tmux -C new-session -A -s \(Self.quoted(session))"
    }

    /// Single-quoted for the remote shell, with any quote of its own escaped.
    ///
    /// Not isolated to the main actor: it is arithmetic on a string, and a test should be
    /// able to check the quoting without pretending to be a user interface.
    nonisolated static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    func connect() async {
        guard case .idle = state else { return }
        // Installed before anything can ask, and awaited rather than left to a task that
        // may not have run: the first thing a connection to a new server does is ask about
        // its host key, and a question raised before the handler exists is a question
        // nobody can answer.
        await prompts.setPromptHandler { [weak self] prompt in
            Task { @MainActor in self?.pendingPrompt = prompt }
        }
        do {
            let established = try await connector.establish { [weak self] step in
                self?.state = .connecting(step: step)
            }
            connection = established.connection
            releaseConnection = established.release

            state = .connecting(step: String(localized: "Starting tmux"))
            let shell = try await established.connection.openCommand(attachCommand)
            self.shell = shell

            let control = TmuxControlSession(transport: ShellTransport(shell: shell), log: log)
            let workspace = TmuxWorkspace(control: control, size: clientSize, log: log)
            self.workspace = workspace

            pumpTask = Task { [weak self] in
                for await event in shell.output {
                    switch event {
                    case let .output(data): await control.receive(Array(data))
                    case .errorOutput: break
                    case .exit, .closed: await control.finish(reason: nil)
                    }
                }
                await control.finish(reason: nil)
                await self?.noteDetached(reason: nil)
            }
            eventTask = Task { [weak self] in
                for await event in workspace.events {
                    await self?.handle(event, from: workspace)
                }
            }

            try await workspace.attach()
            await refresh(from: workspace)
            state = .attached
            log.info("tmux attached", ["host": Redactor.hostname(host.hostname)])
        } catch let error as STError {
            state = .failed(error)
            await tearDown()
        } catch {
            state = .failed(STError(
                category: .internalError,
                message: String(localized: "tmux could not be started on this server."),
                recoverySuggestion: String(localized: "Check that tmux is installed and on the PATH for this account."),
                underlyingDescription: String(describing: error)
            ))
            await tearDown()
        }
    }

    /// Sends what was typed to a pane.
    func send(_ data: Data, to pane: TmuxPaneID) async {
        guard let workspace else { return }
        // Typing scrolls back to the newest output: a keystroke that lands somewhere the
        // user cannot see is the thing every terminal gets right and would be noticed.
        scrollToBottom(pane)
        do {
            try await workspace.send(Array(data), to: pane)
        } catch {
            log.info("input could not be sent to a tmux pane")
        }
    }

    /// Tells tmux how big the view is. Panes are sized from this, so it is what makes the
    /// remote programs' idea of the screen match what is drawn.
    func resize(columns: Int, rows: Int) async {
        let size = (columns: max(columns, 1), rows: max(rows, 1))
        guard size != clientSize else { return }
        clientSize = size
        guard let workspace else { return }
        try? await workspace.setClientSize(columns: size.columns, rows: size.rows)
    }

    func newWindow() async { await perform("new-window") }
    func splitHorizontally() async { await perform("split-window -h") }
    func splitVertically() async { await perform("split-window -v") }

    /// How far back each pane is scrolled, in lines.
    private(set) var scrollOffsets: [TmuxPaneID: Int] = [:]

    /// Scrolls a pane's history.
    ///
    /// Locally, in the pane's own terminal — *not* by asking tmux to enter copy mode.
    /// Measured: `copy-mode` followed by `send-keys -X scroll-up` does scroll tmux's idea
    /// of the pane (`pane_in_mode` becomes 1 and `scroll_position` moves) and sends the
    /// control client **nothing at all**, because copy mode is a view in tmux's own
    /// terminal rather than something a pane writes. A client that scrolled that way would
    /// scroll a screen the user cannot see.
    ///
    /// What makes the local path work is that each pane's terminal is seeded with the real
    /// history when it appears, so there is something to scroll back through.
    func scroll(_ rows: Int, in pane: TmuxPaneID) {
        guard rows != 0 else { return }
        let maximum = snapshot?.terminal(for: pane)?.activeScreen.scrollback.count ?? 0
        scrollOffsets[pane] = min(max(0, (scrollOffsets[pane] ?? 0) + rows), maximum)
    }

    /// Back to the newest output, which is where typing should always land.
    func scrollToBottom(_ pane: TmuxPaneID) {
        scrollOffsets[pane] = 0
    }

    /// Makes a pane the active one, in tmux as well as here.
    func select(pane: TmuxPaneID) async {
        await perform("select-pane -t \(pane)")
    }

    func select(window: TmuxWindowID) async {
        activeWindowID = window
        await perform("select-window -t \(window)")
    }

    func closeActivePane() async {
        // The pane tmux considers active, not the first one in the layout: those are the
        // same thing only in a window that has never been split, and closing the wrong
        // pane is not a mistake anyone can undo.
        guard let pane = activeWindow?.activePane ?? activeWindow?.panes.first else { return }
        await perform("kill-pane -t \(pane)")
    }

    private func perform(_ command: String) async {
        guard let workspace else { return }
        do {
            try await workspace.perform(command)
        } catch let TmuxError.commandFailed(_, message) {
            // tmux's own words, which are more use than anything this app could invent.
            log.info("tmux refused a command", ["message": message])
        } catch {
            log.info("a tmux command could not be sent")
        }
    }

    /// Ends the control session without killing anything on the server: detaching is the
    /// point of tmux, and closing the app must not take the work with it.
    func detach() async {
        await tearDown()
        if case .failed = state {} else { state = .detached(reason: nil) }
    }

    private func tearDown() async {
        eventTask?.cancel()
        eventTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        if let workspace { await workspace.detach() }
        workspace = nil
        if let shell { await shell.close() }
        shell = nil
        await releaseConnection?()
        releaseConnection = nil
        connection = nil
    }

    private func handle(_ event: TmuxWorkspace.Event, from workspace: TmuxWorkspace) async {
        switch event {
        case .windowsChanged, .output:
            await refresh(from: workspace)
        case let .ended(reason):
            await noteDetached(reason: reason)
        }
    }

    private func refresh(from workspace: TmuxWorkspace) async {
        let snapshot = await workspace.snapshot()
        self.snapshot = snapshot
        windows = snapshot.windows
        if let activeWindowID, !windows.contains(where: { $0.id == activeWindowID }) {
            // The window this view was showing has gone; follow tmux rather than showing
            // nothing.
            self.activeWindowID = windows.first?.id
        } else if activeWindowID == nil {
            activeWindowID = windows.first?.id
        }
    }

    private func noteDetached(reason: String?) async {
        guard case .attached = state else { return }
        state = .detached(reason: reason)
        await tearDown()
    }
}

/// Bridges the control session's writes onto the SSH channel.
private struct ShellTransport: TmuxControlTransport {
    let shell: SSHShellSession
    func write(_ bytes: [UInt8]) async throws { try await shell.send(Data(bytes)) }
}
