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
    @Environment(\.scenePhase) private var scenePhase
    /// The compact layout's navigation stack. A split view drives its detail column from
    /// the selection, but a stack has to be pushed explicitly — opening a session and
    /// showing it are two different things, and conflating them is how tapping a host
    /// ends up starting a connection the user never sees.
    @State private var path: [SessionRoute] = []

    /// The consent screen gates everything until the current documents are accepted.
    private var consentBinding: Binding<Bool> {
        Binding(
            get: { container.settings.acceptedTermsVersion < LegalDocument.currentVersion },
            set: { _ in }
        )
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .background(appShortcuts)
        .overlay(alignment: .topLeading) { sceneCountProbe }
        .overlay(alignment: .bottomTrailing) { keyPressProbe }
        // The App Switcher snapshot is taken while the scene is inactive. Covering the
        // terminal then is what "Hide content in the App Switcher" means.
        .overlay {
            if container.settings.hideContentInAppSwitcher, scenePhase != .active {
                PrivacyShield().transition(.opacity)
            }
        }
        .animation(DesignTokens.Motion.standard, value: scenePhase)
        .onAppear { container.activeScene = scene }
        // A session opened by Siri or Shortcuts before this window existed (D-021).
        .onChange(of: container.pendingIntentSessionID, initial: true) { _, pending in
            guard let pending else { return }
            container.pendingIntentSessionID = nil
            scene.selectedSessionID = pending
            if horizontalSizeClass == .compact, !path.contains(.terminal(pending)) { path.append(.terminal(pending)) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                container.activeScene = scene
                container.sync.handleForeground()
            }
        }
        .fullScreenCover(isPresented: consentBinding) {
            ConsentView { container.settings.acceptedTermsVersion = LegalDocument.currentVersion }
                .environment(container)
        }
        .environment(scene)
        .sheet(isPresented: paletteBinding) {
            CommandPaletteView(
                session: container.sessionManager.session(withID: scene.selectedSessionID),
                onOpen: { session in
                    // On a stack-based layout the palette has to push, exactly as the
                    // list does; on a split view the detail column follows the selection.
                    if horizontalSizeClass == .compact, path.last != .terminal(session.id) {
                        path.append(.terminal(session.id))
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
            if current != nil { scene.selectedScreenID = nil }
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
    /// The app's shortcuts, as SwiftUI shortcut buttons that take no space and draw
    /// nothing. They live in the view hierarchy because that is where SwiftUI dispatches a
    /// hardware key when nothing of ours is first responder: the terminal exposes the same
    /// table as `UIKeyCommand`s while it has the keyboard.
    ///
    /// The first design was a hidden `UIView` that made itself first responder whenever
    /// nothing else was. It was measured to expose an iPadOS 26 focus-engine assertion
    /// (`parentEnvironment != nil`, Apple r.154431813): with a hardware keyboard attached,
    /// UIKit re-evaluates the environment it locked to that foreign first responder after
    /// every commit, and scrolling a form sheet then aborted the app in five of eighteen
    /// runs; the same build without the view, and the previous commit, never did in
    /// seventeen. See D-018.
    ///
    /// The buttons keep their titles — that is what the ⌘-hold overlay on iPad lists —
    /// and are `hidden()`, which is the one form of concealment that keeps them out of
    /// the accessibility tree: zero size, zero opacity, `accessibilityHidden` on each
    /// button and an ignored, hidden container all still left eighteen zero-size buttons
    /// answering accessibility queries, so "Command Palette…" matched twice — the real
    /// menu item and the shortcut — which a UI test caught and a dump of the tree proved.
    @ViewBuilder private var appShortcuts: some View {
        ZStack {
            ForEach(AppShortcut.allCases, id: \.rawValue) { shortcut in
                Button(shortcut.title) { container.shortcuts.perform(shortcut) }
                    .keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)
                    .disabled(!container.shortcuts.isAvailable(shortcut))
                    .hidden()
            }
        }
        .frame(width: 0, height: 0)
    }

    /// For the hardware-keyboard UI tests: how many shortcuts ran, and the last one seen.
    /// Debug only, and only when asked for.
    @ViewBuilder private var keyPressProbe: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ST_UITEST_KEY_PROBE"] == "1" {
            Text(verbatim: "\(container.shortcuts.debugShortcutsPerformed)/\(container.shortcuts.debugLast)")
                .font(.caption2)
                .opacity(0.02)
                .accessibilityIdentifier("key-probe")
                .accessibilityValue(Text(verbatim: "\(container.shortcuts.debugShortcutsPerformed)/\(container.shortcuts.debugLast)"))
        }
        #endif
    }

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
            HostListView(
                onOpen: { session in path.append(.terminal(session.id)) },
                onOpenScreen: { screen in path.append(.screen(screen.id)) }
            )
            .navigationDestination(for: SessionRoute.self) { route in
                switch route {
                case let .terminal(id):
                    if let session = container.sessionManager.sessions.first(where: { $0.id == id }) {
                        TerminalView(session: session)
                    } else {
                        EmptyStateView(
                            title: String(localized: "Session closed"),
                            message: String(localized: "This session is no longer open."),
                            systemImage: "terminal"
                        )
                    }
                case let .screen(id):
                    if let screen = container.screens.session(withID: id) {
                        VNCView(session: screen)
                    } else {
                        EmptyStateView(
                            title: String(localized: "Screen closed"),
                            message: String(localized: "This screen is no longer open."),
                            systemImage: "display"
                        )
                    }
                }
            }
        }
    }

    private var regularLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // In a split view the detail column follows the selection, so there is
            // nothing to push.
            HostListView(onOpen: { _ in }, onOpenScreen: { _ in })
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            if let screen = container.screens.session(withID: scene.selectedScreenID) {
                NavigationStack {
                    VNCView(session: screen)
                }
            } else if let session = container.sessionManager.session(withID: scene.selectedSessionID) {
                NavigationStack {
                    TerminalView(session: session)
                }
            } else {
                EmptyStateView(
                    title: String(localized: "No session"),
                    message: String(localized: "Choose a connection to open a terminal."),
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

/// The one command SwiftUI has to own: the system's Settings item and its ⌘, which iOS
/// dispatches itself. Every other shortcut is a `UIKeyCommand` on `AppDelegate`, where a
/// hardware keyboard reaches it whatever has focus — SwiftUI `Commands` never received a
/// hardware ⌘N or ⌘K in the UI tests, on either device.
struct SuperTerminalCommands: Commands {
    let container: AppContainer
    @FocusedValue(\.sceneState) private var focusedScene
    /// The focused scene when there is one, else the active scene — see `AppContainer.activeScene`.
    private var scene: SceneState? { focusedScene ?? container.activeScene }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { scene?.isShowingSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// What the compact layout pushes: a terminal or a remote screen (D-022). One path for
/// both, so Back behaves the same whichever the user opened.
enum SessionRoute: Hashable {
    case terminal(TerminalSession.ID)
    case screen(VNCSession.ID)
}
