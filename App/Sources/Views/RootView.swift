import SwiftUI

/// The app's shell.
///
/// A split view on iPad and a stack on iPhone, driven by the size class rather than the
/// idiom — so a Slide Over window on iPad gets the compact layout, which is the right
/// answer, and Stage Manager resizing moves between them live.
struct RootView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// This window's own state. Created here, so every window gets its own — which is
    /// the whole point of opening a second one.
    @State private var scene: SceneState

    /// A session to show as soon as the window opens, set when the window was opened
    /// from "Open in New Window" rather than from the app icon.
    init(initialSessionID: TerminalSession.ID? = nil) {
        _scene = State(initialValue: SceneState(selectedSessionID: initialSessionID))
    }

    // `.automatic` collapses the sidebar in portrait, which on a fresh install leaves
    // the user staring at "No session" with no visible way to add one. The list is the
    // app's primary surface, so it starts visible and the user can hide it.
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    /// The compact layout's navigation stack. A split view drives its detail column from
    /// the selection, but a stack has to be pushed explicitly — opening a session and
    /// showing it are two different things, and conflating them is how tapping a host
    /// ends up starting a connection the user never sees.
    @State private var path: [TerminalSession.ID] = []

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .overlay(alignment: .topLeading) { sceneCountProbe }
        .environment(scene)
        .sheet(isPresented: paletteBinding) {
            CommandPaletteView(
                session: container.sessionManager.session(withID: scene.selectedSessionID),
                onOpen: { session in
                    // On a stack-based layout the palette has to push, exactly as the
                    // list does; on a split view the detail column follows the selection.
                    if horizontalSizeClass == .compact, path.last != session.id {
                        path.append(session.id)
                    }
                }
            )
            .environment(scene)
        }
        // Tells the menu commands which window they are acting on.
        .focusedSceneValue(\.sceneState, scene)
        .onAppear {
            // A window opened from the app icon shows whatever is already running, but
            // must not steal a session another window is displaying.
            if scene.selectedSessionID == nil {
                scene.selectedSessionID = container.sessionManager.firstUnclaimedSession()?.id
            }
        }
        // The claim follows the window's selection rather than a view's lifetime.
        // Tying it to the terminal view's `onAppear`/`onDisappear` looked equivalent and
        // was not: presenting a sheet over the terminal made the view disappear, which
        // released the claim, and the sheet's dismissal did not always bring it back —
        // leaving the window telling the user their session was open somewhere else.
        .onChange(of: scene.selectedSessionID, initial: true) { previous, current in
            if let previous {
                container.sessionManager.releaseDisplay(ofSessionWithID: previous, by: scene.id)
            }
            if let current {
                container.sessionManager.claimDisplay(ofSessionWithID: current, by: scene.id)
            }
        }
        .onDisappear {
            // The window itself is going away.
            if let id = scene.selectedSessionID {
                container.sessionManager.releaseDisplay(ofSessionWithID: id, by: scene.id)
            }
        }
    }

    /// Reports how many windows the app has, for automated runs only.
    ///
    /// "Open in New Window" is otherwise unverifiable: a screenshot of the result looks
    /// the same whether a second scene was created or the action did nothing, and
    /// XCUITest drives one scene at a time. Debug-only and only while seeded, so it
    /// cannot exist in anything shipped.
    @ViewBuilder
    private var sceneCountProbe: some View {
        #if DEBUG
        if UITestSeeding.seedFromEnvironment != nil {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("scene-count")
                .accessibilityValue("\(UIApplication.shared.connectedScenes.count)")
        }
        #endif
    }

    private var paletteBinding: Binding<Bool> {
        Binding(
            get: { scene.isShowingPalette },
            set: { scene.isShowingPalette = $0 }
        )
    }

    private var compactLayout: some View {
        NavigationStack(path: $path) {
            HostListView { session in
                path.append(session.id)
            }
            .navigationDestination(for: TerminalSession.ID.self) { id in
                if let session = container.sessionManager.sessions.first(where: { $0.id == id }) {
                    TerminalView(session: session)
                } else {
                    EmptyStateView(
                        title: "Session closed",
                        message: "This session is no longer open.",
                        systemImage: "terminal"
                    )
                }
            }
        }
    }

    private var regularLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // In a split view the detail column follows the selection, so there is
            // nothing to push.
            HostListView { _ in }
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            if let session = container.sessionManager.session(withID: scene.selectedSessionID) {
                NavigationStack {
                    TerminalView(session: session)
                }
            } else {
                EmptyStateView(
                    title: "No session",
                    message: "Choose a connection to open a terminal.",
                    systemImage: "terminal"
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// Empty states are a designed screen rather than a blank one: the first thing a new
/// user sees is an empty host list, and it should tell them what to do next.
struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String
    var action: (title: String, perform: () -> Void)?

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Image(systemName: systemImage)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(DesignTokens.Color.labelTertiary)
            Text(title)
                .font(DesignTokens.Typography.title)
            Text(message)
                .font(DesignTokens.Typography.callout)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(DesignTokens.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Menu-bar and ⌘-hold shortcuts. Declaring them here is what makes them discoverable on
/// iPad, where holding Command lists every shortcut the app offers.
///
/// Each command acts on the focused window rather than broadcasting. With two windows
/// open, a broadcast ⌘N opened the sheet in both — including the one the user could not
/// see — and ⌘W, which had no listener at all, did nothing anywhere.
struct SuperTerminalCommands: Commands {
    let container: AppContainer
    @FocusedValue(\.sceneState) private var scene

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Connection…") { scene?.isCreatingConnection = true }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(scene == nil)
            Button("Command Palette…") { scene?.isShowingPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(scene == nil)
        }
        CommandMenu("Session") {
            Button("Next Session") { cycleSession(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(container.sessionManager.sessions.count < 2)
            Button("Previous Session") { cycleSession(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(container.sessionManager.sessions.count < 2)

            Divider()

            // ⌘1…⌘9, the way every browser and terminal numbers its tabs.
            ForEach(1 ... 9, id: \.self) { number in
                Button("Session \(number)") { selectSession(number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    .disabled(container.sessionManager.session(atOneBasedIndex: number) == nil)
            }

            Divider()

            Button("Close Session") {
                guard let session = displayedSession else { return }
                container.sessionManager.close(session)
            }
            .keyboardShortcut("w", modifiers: .command)
            // A shortcut that is listed but does nothing is worse than one that is not
            // listed: the user concludes the app is broken rather than that the command
            // does not apply.
            .disabled(displayedSession == nil)
        }
    }

    @MainActor
    private var displayedSession: TerminalSession? {
        container.sessionManager.session(withID: scene?.selectedSessionID)
    }

    @MainActor
    private func selectSession(_ number: Int) {
        guard let scene, let session = container.sessionManager.session(atOneBasedIndex: number) else { return }
        scene.selectedSessionID = session.id
    }

    @MainActor
    private func cycleSession(by delta: Int) {
        guard let scene else { return }
        guard let session = container.sessionManager.session(after: scene.selectedSessionID, delta: delta) else { return }
        scene.selectedSessionID = session.id
    }
}
