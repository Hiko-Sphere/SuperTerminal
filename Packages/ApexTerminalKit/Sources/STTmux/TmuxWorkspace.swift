import Foundation
import STCore
import STTerminal

/// What a tmux session looks like to a client: its windows, the panes in each, and a
/// terminal for every pane.
///
/// The control session below this is a stream of lines; this is the state those lines
/// describe, kept up to date. Two things about tmux make that more than bookkeeping, and
/// both were measured against a real server rather than assumed:
///
/// * **Attaching to a session that already exists announces almost nothing.** Reattaching
///   to a session with three windows and a split sent one `%session-changed` and no
///   `%window-add` at all. A client that waited for notifications would show an empty
///   workspace over a session full of work, so the state is primed with `list-windows`
///   and the notifications are treated as changes to it.
/// * **The layout is the truth about panes.** tmux announces `%layout-change` with the
///   whole arrangement rather than telling a client which pane appeared; parsing that is
///   how panes are discovered, which is also why the checksum is verified.
public actor TmuxWorkspace {
    public struct Window: Sendable, Identifiable, Equatable {
        public let id: TmuxWindowID
        public var name: String
        public var layout: TmuxLayout
        /// The pane tmux considers active in this window. A client that guessed would put
        /// its focus ring on one pane while tmux's own commands acted on another.
        public var activePane: TmuxPaneID?
        public var panes: [TmuxPaneID] { layout.panes.map(\.id) }
    }

    public enum Event: Sendable, Equatable {
        /// A window was added, removed, renamed, or its arrangement changed.
        case windowsChanged
        /// A pane printed something. The bytes are already in that pane's terminal.
        case output(TmuxPaneID)
        case ended(reason: String?)
    }

    private let control: TmuxControlSession
    private let log: STLogger
    private var terminals: [TmuxPaneID: TerminalEmulator] = [:]
    /// How big a cell is on screen, in pixels. Each pane's terminal is told, because it is
    /// what decides how many cells a picture drawn into that pane covers (D-065).
    private var cellSize = TerminalEmulator.CellSize.unmeasured
    /// Panes whose existing contents have already been fetched.
    ///
    /// Control mode sends `%output` only for what a pane writes *from now on*. Attaching
    /// to a session that has been running for a week therefore shows nothing at all until
    /// something new is printed — measured, and the reason this exists: a pane's current
    /// screen and history are asked for once, with `capture-pane`, and fed to its terminal
    /// as if the pane had just written them.
    private var captured: Set<TmuxPaneID> = []
    /// How much history to ask for. tmux's own default `history-limit` is 2000 lines, and
    /// asking for more than the pane has is not an error.
    private let historyLines: Int
    private var windowsByID: [TmuxWindowID: Window] = [:]
    private var pump: Task<Void, Never>?

    private var eventContinuation: AsyncStream<Event>.Continuation?
    public nonisolated let events: AsyncStream<Event>

    /// Bumped whenever the state is replaced from any source. A reload captures it before
    /// asking tmux and discards its own answer if anything newer landed while it waited:
    /// this is an actor, so an `await` is a suspension point, and two reloads in flight can
    /// come back in the other order. Measured — a resize looked as though tmux had ignored
    /// it, because an older `list-windows` reply overwrote the layout change that followed
    /// it.
    private var stateGeneration = 0
    /// The arrival order this workspace's state already reflects.
    ///
    /// A reload's answer describes the server as it was when the question was asked, so it
    /// accounts for every notification that had arrived by then. Replaying one of those
    /// afterwards puts back an arrangement the server has left — measured: a reload applied
    /// a split, and a `%layout-change` from *before* it, still queued behind a slower pump,
    /// then removed it again.
    private var appliedLayoutSequence = 0
    private var reloadInFlight = false
    private var reloadAgain = false
    /// Callers waiting for the reload that is already running.
    ///
    /// Coalescing must not turn `reload()` into "someone else will do it eventually":
    /// `attach()` returns to a caller that immediately reads the windows, and returning
    /// before they exist showed an empty workspace over a live session — measured, three
    /// tests in a row.
    private var reloadWaiters: [CheckedContinuation<Void, any Error>] = []

    /// The size the client is showing, in cells. tmux sizes its panes to the smallest
    /// attached client, so this is what makes the arrangement fit the screen it is on.
    private var clientSize: (columns: Int, rows: Int)

    public init(
        control: TmuxControlSession,
        size: (columns: Int, rows: Int) = (80, 24),
        historyLines: Int = 2000,
        log: STLogger = .disabled
    ) {
        self.control = control
        self.log = log
        self.historyLines = historyLines
        clientSize = size
        var continuation: AsyncStream<Event>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    public var windows: [Window] { windowsByID.values.sorted { $0.id.number < $1.id.number } }

    public func window(_ id: TmuxWindowID) -> Window? { windowsByID[id] }

    /// A snapshot of what a pane is showing. A copy, because the emulator is a value and
    /// handing out a reference to a live one would let a caller see it change under them.
    /// The windows and every pane's terminal, read together.
    ///
    /// Two separate reads of an actor are two separate moments, and the state can move
    /// between them — a caller that asked for the panes and then for their terminals could
    /// be handed a pane that no longer exists. Everything that draws the workspace takes one
    /// of these, and there is deliberately no way to ask the actor for a single pane's
    /// terminal: returning one `TerminalEmulator` by value out of an actor crashed the test
    /// suite twice, in `outlined destroy of TerminalEmulator?` under a `#expect` expansion,
    /// each time the struct grew (D-058, D-065). A snapshot hands over a dictionary, which
    /// is one retained buffer rather than a large value copied across a suspension.
    public func snapshot() -> Snapshot {
        Snapshot(windows: windows, terminals: terminals)
    }

    public struct Snapshot: Sendable {
        public let windows: [Window]
        public let terminals: [TmuxPaneID: TerminalEmulator]

        public func terminal(for pane: TmuxPaneID) -> TerminalEmulator? { terminals[pane] }
        /// The size a pane's terminal is showing, in cells.
        public func size(of pane: TmuxPaneID) -> (columns: Int, rows: Int)? {
            guard let terminal = terminals[pane] else { return nil }
            return (terminal.activeScreen.columns, terminal.activeScreen.rows)
        }
    }

    /// Learns the current state and starts following changes.
    public func attach() async throws {
        pump = Task { [weak self] in
            guard let self else { return }
            for await event in self.control.notifications {
                await self.apply(event)
            }
            await self.finish(reason: nil)
        }
        try await setClientSize(columns: clientSize.columns, rows: clientSize.rows)
        try await reload()
    }

    public func detach() async {
        pump?.cancel()
        pump = nil
        await control.finish(reason: nil)
        finish(reason: nil)
    }

    /// Tells tmux how big this client's view is, in cells.
    public func setClientSize(columns: Int, rows: Int) async throws {
        clientSize = (max(columns, 1), max(rows, 1))
        try await control.send("refresh-client -C \(clientSize.columns)x\(clientSize.rows)")
    }

    /// Sends bytes to a pane, as bytes.
    ///
    /// `send-keys -H` takes hex, which is the only form that carries everything a terminal
    /// must send: control characters, escape sequences and UTF-8 alike, with no quoting to
    /// get wrong. Sending the text instead would need tmux's own key names for anything
    /// that is not a printable character.
    public func send(_ bytes: [UInt8], to pane: TmuxPaneID) async throws {
        guard !bytes.isEmpty else { return }
        // In chunks, because a command line has a limit and a paste does not.
        for chunk in stride(from: 0, to: bytes.count, by: 256).map({ start in
            Array(bytes[start ..< min(start + 256, bytes.count)])
        }) {
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            try await control.send("send-keys -t \(pane) -H \(hex)")
        }
    }

    /// Runs a tmux command and hands back its reply, for the things a client does not model.
    @discardableResult
    public func perform(_ command: String) async throws -> [String] {
        try await control.send(command)
    }

    /// Asks tmux what it has, rather than inferring it.
    ///
    /// Used on attach and whenever a window appears or disappears: those notifications say
    /// *that* something changed, not what the new arrangement is, and one round trip is
    /// cheaper than a wrong picture.
    public func reload() async throws {
        // One at a time. Overlapping reloads are the race described above, and asking twice
        // at once is also two round trips for one answer — but a second caller waits for
        // the answer rather than being told to go away.
        if reloadInFlight {
            reloadAgain = true
            try await withCheckedThrowingContinuation { continuation in
                reloadWaiters.append(continuation)
            }
            return
        }
        reloadInFlight = true

        do {
            try await runReload()
        } catch {
            reloadInFlight = false
            finishWaiters(with: error)
            throw error
        }
        reloadInFlight = false
        finishWaiters(with: nil)
    }

    private func finishWaiters(with error: (any Error)?) {
        let waiting = reloadWaiters
        reloadWaiters.removeAll()
        for continuation in waiting {
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }

    private func runReload() async throws {
        repeat {
            reloadAgain = false
            // Counted where the bytes arrive, not where they are handled: a `%layout-change`
            // that overtook this answer may not have been applied yet, and comparing applied
            // state would call the stale answer fresh.
            let sequence = await control.layoutSequence
            let lines = try await control.send(
                ##"list-windows -F "#{window_id} #{window_layout} #{window_name}""##
            )
            guard await control.layoutSequence == sequence else {
                // The arrangement moved while this was in flight, so this answer describes
                // something the server no longer has. Ask again rather than apply it.
                reloadAgain = true
                continue
            }

            // Which pane is active is a pane fact, not a window one, so it takes a second
            // question. Asked inside the same guarded round as the layouts so the two
            // describe the same moment.
            let paneLines = (try? await control.send(
                ##"list-panes -a -F "#{window_id} #{pane_id} #{pane_active}""##
            )) ?? []
            var activePanes: [TmuxWindowID: TmuxPaneID] = [:]
            for line in paneLines {
                let fields = line.split(separator: " ")
                guard fields.count >= 3, fields[2] == "1",
                      let window = TmuxControlParser.windowID(String(fields[0])),
                      let pane = TmuxControlParser.paneID(String(fields[1]))
                else { continue }
                activePanes[window] = pane
            }

            var rebuilt: [TmuxWindowID: Window] = [:]
            for line in lines {
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count >= 2,
                      let id = TmuxControlParser.windowID(String(fields[0]))
                else {
                    log.info("a window line could not be read")
                    continue
                }
                do {
                    let layout = try TmuxLayout.parse(String(fields[1]))
                    rebuilt[id] = Window(
                        id: id,
                        name: fields.count > 2 ? String(fields[2]) : "",
                        layout: layout,
                        activePane: activePanes[id] ?? layout.panes.first?.id
                    )
                } catch {
                    // A layout that will not parse is reported and the window is dropped
                    // rather than the whole reload failing: the other windows are still
                    // usable, and one window missing is visibly wrong rather than a
                    // workspace that silently stopped updating.
                    log.error("a window layout could not be parsed", ["error": String(describing: error)])
                }
            }
            windowsByID = rebuilt
            stateGeneration += 1
            // This answer reflects everything that had arrived when it was asked for.
            appliedLayoutSequence = max(appliedLayoutSequence, sequence)
            reconcileTerminals()
            eventContinuation?.yield(.windowsChanged)
            await captureNewPanes()
        } while reloadAgain
    }

    // MARK: - Applying what the server says

    private func apply(_ event: TmuxEvent) async {
        switch event.notification {
        case let .output(pane, bytes), let .extendedOutput(pane, _, bytes):
            guard terminals[pane] != nil else {
                // Output for a pane this client has not heard of: the arrangement changed
                // and the notification arrived first. Reloading is what makes it appear.
                log.debug("output for an unknown pane", ["pane": pane.description])
                try? await reload()
                feed(bytes, into: pane)
                return
            }
            feed(bytes, into: pane)

        case let .layoutChange(window, layout, _, _):
            guard event.layoutSequence > appliedLayoutSequence else {
                // Already accounted for by a reload that overtook it.
                log.debug("a layout change older than the state was skipped")
                return
            }
            do {
                let parsed = try TmuxLayout.parse(layout)
                if var existing = windowsByID[window] {
                    existing.layout = parsed
                    // A pane that has gone cannot stay active.
                    if let active = existing.activePane, !parsed.panes.contains(where: { $0.id == active }) {
                        existing.activePane = parsed.panes.first?.id
                    }
                    windowsByID[window] = existing
                } else {
                    windowsByID[window] = Window(
                        id: window,
                        name: "",
                        layout: parsed,
                        activePane: parsed.panes.first?.id
                    )
                }
                // Newer than anything a reload could still be waiting for.
                stateGeneration += 1
                appliedLayoutSequence = event.layoutSequence
                reconcileTerminals()
                eventContinuation?.yield(.windowsChanged)
                await captureNewPanes()
            } catch {
                log.error("a layout change could not be parsed", ["error": String(describing: error)])
            }

        case let .windowRenamed(window, name):
            guard var existing = windowsByID[window] else { return }
            existing.name = name
            windowsByID[window] = existing
            stateGeneration += 1
            appliedLayoutSequence = max(appliedLayoutSequence, event.layoutSequence)
            eventContinuation?.yield(.windowsChanged)

        case let .windowPaneChanged(window, pane):
            guard var existing = windowsByID[window] else { return }
            existing.activePane = pane
            windowsByID[window] = existing
            stateGeneration += 1
            appliedLayoutSequence = max(appliedLayoutSequence, event.layoutSequence)
            eventContinuation?.yield(.windowsChanged)

        case .windowAdd, .windowClose, .sessionChanged, .sessionWindowChanged, .unlinkedWindowAdd:
            // These say something changed without saying what it now is. A reload that has
            // already accounted for this one is not repeated.
            guard event.layoutSequence > appliedLayoutSequence else { return }
            try? await reload()

        case let .exit(reason):
            finish(reason: reason)

        default:
            break
        }
    }

    /// Fetches what each new pane already has on it, once.
    ///
    /// `-e` keeps the colours and attributes, `-J` rejoins lines tmux wrapped, and `-S`
    /// reaches back into the history. The result is fed to the pane's terminal like any
    /// other output, so a reattached pane looks the way it did when it was left rather
    /// than blank.
    private func captureNewPanes() async {
        let wanted = Set(terminals.keys).subtracting(captured)
        for pane in wanted.sorted(by: { $0.number < $1.number }) {
            captured.insert(pane)
            do {
                let lines = try await control.send(
                    "capture-pane -p -e -J -S -\(historyLines) -t \(pane)"
                )
                guard !lines.isEmpty else { continue }
                // Newlines between the lines but not after the last, so the cursor stays
                // where tmux left it rather than one row lower.
                feed(Array(lines.joined(separator: "\r\n").utf8), into: pane)
            } catch {
                // A pane that has gone between the layout and this question is not a
                // failure; the arrangement will catch up.
                log.debug("a pane's contents could not be captured", ["pane": pane.description])
                captured.remove(pane)
            }
        }
    }

    private func feed(_ bytes: [UInt8], into pane: TmuxPaneID) {
        guard var emulator = terminals[pane] else { return }
        _ = emulator.feed(bytes)
        terminals[pane] = emulator
        eventContinuation?.yield(.output(pane))
    }

    /// One terminal per pane, sized as tmux says that pane is.
    ///
    /// A pane that has gone takes its terminal with it: keeping them would leak a
    /// scrollback per split for as long as the session lasted.
    private func reconcileTerminals() {
        var wanted: Set<TmuxPaneID> = []
        for window in windowsByID.values {
            for (id, frame) in window.layout.panes {
                wanted.insert(id)
                if var existing = terminals[id] {
                    existing.resize(columns: frame.width, rows: frame.height)
                    existing.cellSize = cellSize
                    terminals[id] = existing
                } else {
                    var made = TerminalEmulator(columns: frame.width, rows: frame.height)
                    made.cellSize = cellSize
                    terminals[id] = made
                }
            }
        }
        for id in terminals.keys where !wanted.contains(id) {
            terminals.removeValue(forKey: id)
            captured.remove(id)
        }
    }

    /// Tells every pane how big a cell is, so a picture drawn into one covers the right
    /// number of them (D-065).
    public func setCellSize(width: Int, height: Int) {
        let size = TerminalEmulator.CellSize(width: width, height: height)
        guard size != cellSize else { return }
        cellSize = size
        for id in terminals.keys { terminals[id]?.cellSize = size }
    }

    private func finish(reason: String?) {
        guard eventContinuation != nil else { return }
        eventContinuation?.yield(.ended(reason: reason))
        eventContinuation?.finish()
        eventContinuation = nil
    }
}
