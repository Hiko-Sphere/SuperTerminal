import STTerminal
import STTmux
import SwiftUI

/// A tmux window: its panes, arranged the way tmux says they are.
///
/// The layout is drawn from tmux's own cell rectangles rather than converted into the app's
/// pane tree. tmux gives an exact grid — a pane is at (x, y) and is w×h cells of a window
/// that is W×H — so placing each pane at that fraction of the view reproduces the server's
/// arrangement exactly, including the arrangements a binary tree cannot express. The app's
/// own splitting is not offered here on purpose: in a tmux session the server owns the
/// layout, and two things deciding it would fight.
struct TmuxWindowView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let session: TmuxSession
    /// Whether this view should hold the keyboard.
    let wantsKeyboard: Bool

    private var theme: TerminalTheme {
        TerminalThemeResolver(settings: container.settings).theme(
            colorScheme: colorScheme,
            differentiateWithoutColor: differentiateWithoutColor,
            increaseContrast: colorSchemeContrast == .increased,
            hostOverride: session.host.themeID
        )
    }

    var body: some View {
        Group {
            switch session.state {
            case .idle, .connecting:
                connecting
            case .attached:
                if let window = session.activeWindow, let snapshot = session.snapshot {
                    panes(of: window, snapshot: snapshot)
                } else {
                    EmptyStateView(
                        title: String(localized: "No tmux windows"),
                        message: String(localized: "This tmux session has no windows. Create one to start working."),
                        systemImage: "rectangle.on.rectangle",
                        action: (title: String(localized: "New Window"), perform: { Task { await session.newWindow() } })
                    )
                }
            case let .failed(error):
                EmptyStateView(
                    title: String(localized: "tmux could not start"),
                    message: error.recoverySuggestion ?? error.message,
                    systemImage: "exclamationmark.triangle"
                )
            case let .detached(reason):
                EmptyStateView(
                    title: String(localized: "Detached"),
                    message: reason ?? String(localized: "The tmux session is still running on the server. Open the connection again to attach to it."),
                    systemImage: "bolt.slash"
                )
            }
        }
        .background(theme.background.swiftUIColor)
        .navigationTitle(session.host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        // The same sheet a terminal raises, for the same questions: attaching runs the
        // whole connection path, so a host key nobody has seen before must stop tmux
        // exactly as it stops a shell.
        .sheet(item: promptBinding) { prompt in
            PromptSheet(prompt: prompt) { decision in session.resolvePrompt(decision) }
        }
        .task(id: session.id) { await session.connect() }
    }

    private var promptBinding: Binding<TerminalSession.PendingPrompt?> {
        Binding(
            get: { session.pendingPrompt },
            // Dismissing without answering is a refusal, which for a host key is the
                // safe reading and for a password is simply "not now".
                set: { if $0 == nil { session.resolvePrompt(.reject) } }
        )
    }

    private var connecting: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            ProgressView()
            if case let .connecting(step) = session.state {
                Text(step)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func panes(of window: TmuxWorkspace.Window, snapshot: TmuxWorkspace.Snapshot) -> some View {
        GeometryReader { proxy in
            let frame = window.layout.frame
            let cellWidth = frame.width > 0 ? proxy.size.width / CGFloat(frame.width) : 0
            let cellHeight = frame.height > 0 ? proxy.size.height / CGFloat(frame.height) : 0
            ZStack(alignment: .topLeading) {
                ForEach(window.layout.panes, id: \.id) { pane in
                    paneView(pane.id, in: window, snapshot: snapshot)
                        .frame(
                            width: max(CGFloat(pane.frame.width) * cellWidth, 1),
                            height: max(CGFloat(pane.frame.height) * cellHeight, 1)
                        )
                        .offset(
                            x: CGFloat(pane.frame.x) * cellWidth,
                            y: CGFloat(pane.frame.y) * cellHeight
                        )
                }
            }
            // The view's size in cells is what tmux is told, so the arrangement it sends
            // back fits exactly. Measured in the terminal's own cell size rather than
            // guessed, so a different font size changes the number of cells rather than
            // the size of the text.
            .task(id: proxy.size) {
                let metrics = TerminalRenderView.metrics(
                    forFontSize: container.settings.fontSize,
                    family: container.settings.fontFamily,
                    lineHeightMultiple: container.settings.lineHeightMultiple
                )
                await session.resize(
                    columns: max(Int(proxy.size.width / metrics.cellWidth), 1),
                    rows: max(Int(proxy.size.height / metrics.cellHeight), 1),
                    cellWidth: Int(metrics.cellWidth),
                    cellHeight: Int(metrics.cellHeight)
                )
            }
        }
    }

    @ViewBuilder
    private func paneView(
        _ pane: TmuxPaneID,
        in window: TmuxWorkspace.Window,
        snapshot: TmuxWorkspace.Snapshot
    ) -> some View {
        let isActive = window.activePane == pane
        if let emulator = snapshot.terminal(for: pane) {
            TmuxPaneView(
                session: session,
                pane: pane,
                screen: emulator.activeScreen,
                theme: theme,
                fontSize: container.settings.fontSize,
                fontFamily: container.settings.fontFamily,
                lineHeightMultiple: container.settings.lineHeightMultiple,
                ligaturesEnabled: container.settings.fontLigatures,
                blinkCursor: container.settings.cursorBlink,
                scrollbackOffset: session.scrollOffsets[pane] ?? 0,
                wantsKeyboard: wantsKeyboard && isActive,
                onHaptic: { container.haptics.play($0) },
                onCopy: { Clipboard.copy($0, expiringAfter: container.settings.clipboardExpirySeconds) }
            )
            .overlay {
                Rectangle()
                    .strokeBorder(
                        isActive ? DesignTokens.Color.accent : DesignTokens.Color.separator,
                        lineWidth: isActive ? 2 : 0.5
                    )
            }
            // Tapping a pane makes it the active one *in tmux*, not just here: the app's
            // idea of which pane is focused and the server's have to be the same one, or
            // every tmux command acts somewhere the user is not looking.
            .simultaneousGesture(TapGesture().onEnded {
                Task { await session.select(pane: pane) }
            })
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                isActive
                    ? String(localized: "tmux pane \(pane.number), active")
                    : String(localized: "tmux pane \(pane.number)")
            )
            .accessibilityIdentifier("tmux-pane-\(pane.number)")
        } else {
            // A pane tmux has told us about but whose terminal has not arrived yet.
            Color.clear
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section(String(localized: "Windows")) {
                    ForEach(session.windows) { window in
                        Button {
                            Task { await session.select(window: window.id) }
                        } label: {
                            Label(
                                window.name.isEmpty ? String(localized: "Window \(window.id.number)") : window.name,
                                systemImage: window.id == session.activeWindow?.id ? "checkmark" : "rectangle"
                            )
                        }
                    }
                }
                Section {
                    Button(String(localized: "New Window"), systemImage: "plus.rectangle") {
                        Task { await session.newWindow() }
                    }
                    .accessibilityIdentifier("tmux-new-window")
                    Button(String(localized: "Split Right"), systemImage: "rectangle.split.2x1") {
                        Task { await session.splitHorizontally() }
                    }
                    .accessibilityIdentifier("tmux-split-right")
                    Button(String(localized: "Split Down"), systemImage: "rectangle.split.1x2") {
                        Task { await session.splitVertically() }
                    }
                    Button(String(localized: "Close Pane"), systemImage: "rectangle.badge.minus", role: .destructive) {
                        Task { await session.closeActivePane() }
                    }
                }
                Section {
                    // Detach, not disconnect: what is running stays running on the server,
                    // which is the reason to use tmux in the first place.
                    Button(String(localized: "Detach"), systemImage: "bolt.slash") {
                        Task { await session.detach() }
                    }
                }
            } label: {
                Label(String(localized: "tmux"), systemImage: "square.split.bottomrightquarter")
            }
            .accessibilityIdentifier("tmux-menu")
        }
    }
}
