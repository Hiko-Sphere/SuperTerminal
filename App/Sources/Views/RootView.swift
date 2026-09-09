import CoreSpotlight
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
    /// The window scene this root ended up in, which the lock window attaches to (D-023).
    @State private var lockScene: UIWindowScene?

    /// What a first run still owes the user, in order (D-033). One value rather than two
    /// covers: `fullScreenCover` does not reliably stack, and the tour must not race the
    /// documents it comes after.
    private enum FirstRun: Identifiable {
        case consent, tutorial
        var id: Self { self }
    }

    private var firstRun: FirstRun? {
        if container.settings.acceptedTermsVersion < LegalDocument.currentVersion { return .consent }
        if !container.settings.hasSeenTutorial { return .tutorial }
        return nil
    }

    private var firstRunBinding: Binding<FirstRun?> {
        Binding(get: { firstRun }, set: { _ in })
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
        .background(WindowSceneReader { windowScene in
            lockScene = windowScene
            syncLockWindow()
        })
        .onChange(of: container.appLock.isLocked, initial: true) { _, _ in syncLockWindow() }
        .overlay(alignment: .topLeading) { sceneCountProbe }
        .overlay(alignment: .topTrailing) { paneCountProbe }
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
            container.appLock.handleScenePhase(phase)
            if phase == .active {
                container.activeScene = scene
                container.sync.handleForeground()
            }
        }
        .fullScreenCover(item: firstRunBinding) { step in
            switch step {
            case .consent:
                ConsentView { container.settings.acceptedTermsVersion = LegalDocument.currentVersion }
                    .environment(container)
            case .tutorial:
                TutorialView { container.settings.hasSeenTutorial = true }
                    .environment(container)
            }
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
        // The guide opens over whatever raised the question — ⌘/ from a terminal, or the
        // row in Settings — rather than replacing it (D-056).
        .sheet(isPresented: helpBinding) { HelpView() }
        // Links, search results and handovers (D-061), in one modifier: a `body` this long
        // stops type-checking in a Release build long before it stops compiling in a Debug
        // one — measured, as an archive that failed while every simulator build passed.
        .modifier(IncomingLinks(
            receive: { container.links.receive($0) },
            receiveActivity: { container.links.receive(activity: $0) },
            pending: pendingLinkBinding,
            approve: { container.links.approvePending() },
            cancel: { container.links.dismissPending() },
            isReady: container.links.ready != nil,
            perform: performReadyLink
        ))
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
        // ⌘1…⌘9 and ⌘⇧] only change the selection; in a stack layout the terminal on
        // screen is whatever was pushed, so without this the shortcut swapped the claim
        // out from under the visible terminal and replaced it with "Open in another
        // window" (D-025).
        .onChange(of: scene.selectedSessionID) { _, current in
            guard horizontalSizeClass == .compact, let current else { return }
            if path.last != .terminal(current) {
                if case .terminal = path.last { path[path.count - 1] = .terminal(current) } else { path.append(.terminal(current)) }
            }
        }
        .onChange(of: scene.selectedSessionID, initial: true) { previous, current in
            if current != nil { scene.selectedScreenID = nil }
            if let previous {
                container.sessionManager.releaseDisplay(ofSessionWithID: previous, by: scene.id)
            }
            if let current {
                container.sessionManager.claimDisplay(ofSessionWithID: current, by: scene.id)
            }
        }
        // Every pane in this window displays its session, not just the selected one
        // (D-055). Display ownership was written when a window showed exactly one session,
        // and a second pane was therefore told its session was "showing in a different
        // window" — the app refusing to draw a terminal it was already showing.
        .onChange(of: scene.panes, initial: true) { previous, current in
            let held = Set(previous.panes.compactMap { pane -> UUID? in
                if case let .terminal(id) = pane.content { return id }
                return nil
            })
            let wanted = Set(current.panes.compactMap { pane -> UUID? in
                if case let .terminal(id) = pane.content { return id }
                return nil
            })
            for id in held.subtracting(wanted) {
                container.sessionManager.releaseDisplay(ofSessionWithID: id, by: scene.id)
            }
            for id in wanted {
                container.sessionManager.claimDisplay(ofSessionWithID: id, by: scene.id)
            }
        }
        .onDisappear {
            // The window itself is going away: everything it was showing is let go.
            for pane in scene.panes.panes {
                if case let .terminal(id) = pane.content {
                    container.sessionManager.releaseDisplay(ofSessionWithID: id, by: scene.id)
                }
            }
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
    /// Shows or hides the lock in a window above this scene's own (D-023).
    private func syncLockWindow() {
        guard let lockScene else { return }
        if container.appLock.isLocked {
            let container = container
            container.lockWindows.show(in: lockScene) {
                AnyView(LockScreenView(lock: container.appLock).environment(container))
            }
        } else {
            container.lockWindows.hide(in: lockScene)
        }
    }

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

    /// How many panes this window is showing, for UI tests. Debug only.
    ///
    /// Counting terminals on screen is ambiguous — two panes on one server carry the same
    /// accessibility label — so the layout says what it holds.
    @ViewBuilder
    private var paneCountProbe: some View {
        #if DEBUG
        if UITestSeeding.seedFromEnvironment != nil {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("pane-count")
                .accessibilityValue("\(scene.panes.paneCount)")
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

    private var pendingLinkBinding: Binding<LinkCoordinator.Pending?> {
        Binding(
            get: { container.links.pending },
            // Swiping the sheet away is a refusal, which for a link is the safe reading.
            set: { if $0 == nil { container.links.dismissPending() } }
        )
    }

    /// Carries out a link that has been authorised.
    ///
    /// Opening goes through the same path as a tap on the row — host key checks,
    /// credentials, prompts — because a link is a way in, not a way around. A command is
    /// typed into the session once it is connected, exactly as if the user had typed it.
    private func performReadyLink() {
        guard let outcome = container.links.consumeReady() else { return }
        switch outcome {
        case let .open(hostID):
            openFromLink(hostID: hostID, command: nil)
        case let .openAndRun(hostID, command):
            openFromLink(hostID: hostID, command: command)
        case let .offerToAdd(address):
            // Filled in, not saved: the list must only ever contain what somebody chose to
            // put there.
            scene.linkDraft = address
            scene.isCreatingConnection = true
        case .ignored:
            break
        }
    }

    private func openFromLink(hostID: UUID, command: String?) {
        guard let host = container.hostStore.hosts.first(where: { $0.id == hostID }) else { return }
        if host.isUsingTmux, let session = container.tmux.open(host) {
            scene.show(tmux: session.id)
            if horizontalSizeClass == .compact { path.append(.tmux(session.id)) }
            return
        }
        let session = container.sessionManager.open(host)
        container.hostStore.markConnected(host)
        scene.show(terminal: session.id)
        if horizontalSizeClass == .compact { path.append(.terminal(session.id)) }
        guard let command else { return }
        Task { @MainActor in
            // Waits for the shell before typing: sending into a session that has not
            // connected drops the bytes, and a command that silently did not run is worse
            // than one that visibly did not.
            await session.sendWhenConnected(command + "\n")
        }
    }

    private var helpBinding: Binding<Bool> {
        Binding(
            get: { scene.isShowingHelp },
            set: { scene.isShowingHelp = $0 }
        )
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
                onOpenFiles: { session in path.append(.files(session.id)) },
                onOpenScreen: { screen in path.append(.screen(screen.id)) },
                onOpenTmux: { session in path.append(.tmux(session.id)) }
            )
            .navigationDestination(for: SessionRoute.self) { route in
                // A phone splits too (D-056). Panes were built into the split view's detail
                // column only, so on a compact layout "Split Right" changed the model and
                // nothing on screen — a menu item that appears to do nothing, which is
                // worse than one that is not offered. Measured on iPhone: the layout held
                // two panes and exactly one terminal was in the accessibility tree.
                if scene.panes.paneCount > 1, scene.panes.panes.contains(where: { $0.content == route.paneContent }) {
                    PaneContainerView(layout: paneBinding, panesShareOneToolbar: true) { content in
                        paneContent(content, wrappedInItsOwnStack: false)
                    }
                    .padding(DesignTokens.Spacing.xs)
                } else {
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
                    case let .tmux(id):
                        if let session = container.tmux.session(withID: id) {
                            TmuxWindowView(session: session, wantsKeyboard: true)
                        } else {
                            EmptyStateView(
                                title: String(localized: "Session ended"),
                                message: String(localized: "This tmux session is no longer attached."),
                                systemImage: "square.split.bottomrightquarter"
                            )
                        }
                    case let .files(id):
                        if let session = container.sessionManager.fileSession(id: id) {
                            FileBrowserView(session: session, wrapsInItsOwnStack: false)
                        } else {
                            EmptyStateView(
                                title: String(localized: "Browser closed"),
                                message: String(localized: "This file browser is no longer open."),
                                systemImage: "folder"
                            )
                        }
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
            // One pane or several, drawn the same way (D-055): with a single pane this is
            // exactly what it was before, and an arrangement grows from there rather than
            // being a separate mode to enter.
            PaneContainerView(layout: paneBinding) { content in
                paneContent(content)
            }
            .padding(DesignTokens.Spacing.xs)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Keeps the pane tree and the list's selection in step: the list selects, the panes
    /// display, and a session that has gone must not leave a pane pointing at nothing.
    private var paneBinding: Binding<PaneLayout> {
        Binding(
            get: {
                var layout = scene.panes
                if layout.paneCount == 0 {
                    if let screen = container.screens.session(withID: scene.selectedScreenID) {
                        layout = PaneLayout(content: .screen(screen.id))
                    } else if let session = container.sessionManager.session(withID: scene.selectedSessionID) {
                        layout = PaneLayout(content: .terminal(session.id))
                    } else if let session = container.tmux.session(withID: scene.selectedTmuxSessionID) {
                        layout = PaneLayout(content: .tmux(session.id))
                    }
                }
                return layout
            },
            set: { scene.panes = $0 }
        )
    }

    private func paneContent(_ content: PaneLayout.Content, wrappedInItsOwnStack: Bool = true) -> AnyView {
        switch content {
        case let .terminal(id):
            if let session = container.sessionManager.session(withID: id) {
                wrappedInItsOwnStack
                    ? AnyView(NavigationStack { TerminalView(session: session) })
                    : AnyView(TerminalView(session: session))
            } else {
                // The session ended while a pane was showing it. Saying so beats a blank
                // rectangle, and the pane can still be closed.
                AnyView(
                    EmptyStateView(
                        title: String(localized: "Session ended"),
                        message: String(localized: "This session is no longer open. Close the pane, or choose a connection."),
                        systemImage: "terminal"
                    )
                )
            }
        case let .files(id):
            if let session = container.sessionManager.fileSession(id: id) {
                AnyView(FileBrowserView(session: session, wrapsInItsOwnStack: wrappedInItsOwnStack))
            } else {
                AnyView(
                    EmptyStateView(
                        title: String(localized: "Browser closed"),
                        message: String(localized: "This file browser is no longer open. Close the pane, or open a server's files again."),
                        systemImage: "folder"
                    )
                )
            }
        case let .tmux(id):
            if let session = container.tmux.session(withID: id) {
                wrappedInItsOwnStack
                    ? AnyView(NavigationStack { TmuxWindowView(session: session, wantsKeyboard: true) })
                    : AnyView(TmuxWindowView(session: session, wantsKeyboard: true))
            } else {
                AnyView(
                    EmptyStateView(
                        title: String(localized: "Session ended"),
                        message: String(localized: "This tmux session is no longer attached. Open the connection again to attach to it."),
                        systemImage: "square.split.bottomrightquarter"
                    )
                )
            }
        case let .screen(id):
            if let screen = container.screens.session(withID: id) {
                wrappedInItsOwnStack
                    ? AnyView(NavigationStack { VNCView(session: screen) })
                    : AnyView(VNCView(session: screen))
            } else {
                AnyView(
                    EmptyStateView(
                        title: String(localized: "Screen closed"),
                        message: String(localized: "This screen is no longer open. Close the pane, or choose a connection."),
                        systemImage: "display"
                    )
                )
            }
        }
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
struct ApexTerminalCommands: Commands {
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
    case tmux(UUID)
    /// A file browser, which is a session like the others now that more than one can be
    /// open (D-071).
    case files(UUID)

    /// The same thing, said in the pane tree's vocabulary — so a pushed route can ask
    /// whether the arrangement on screen is showing it.
    var paneContent: PaneLayout.Content {
        switch self {
        case let .terminal(id): .terminal(id)
        case let .screen(id): .screen(id)
        case let .tmux(id): .tmux(id)
        case let .files(id): .files(id)
        }
    }
}


/// Everything that arrives from outside the app: a link, a Spotlight result, a handover
/// (D-061).
///
/// A modifier rather than another dozen lines on `RootView.body`. The body had grown past
/// what the Release optimiser will type-check — the Debug builds were fine and the archive
/// was not — and grouping this makes the reason it is here readable as well.
private struct IncomingLinks: ViewModifier {
    let receive: (URL) -> Void
    let receiveActivity: (NSUserActivity) -> Void
    let pending: Binding<LinkCoordinator.Pending?>
    let approve: () -> Void
    let cancel: () -> Void
    let isReady: Bool
    let perform: () -> Void

    func body(content: Content) -> some View {
        content
            .onOpenURL { receive($0) }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                receiveActivity(activity)
                perform()
            }
            .onContinueUserActivity(SessionActivity.type) { activity in
                receiveActivity(activity)
                perform()
            }
            .sheet(item: pending) { pending in
                LinkConfirmationSheet(pending: pending, onApprove: approve, onCancel: cancel)
            }
            .onChange(of: isReady) { _, _ in perform() }
            .onAppear {
                perform()
                #if DEBUG
                // A UI run's link arrives here rather than from the system, which cannot
                // hand an app a URL without driving Safari. `UITestSeeding` does not exist
                // in a Release build, so neither does this.
                if let link = UITestSeeding.linkFromEnvironment { receive(link) }
                #endif
            }
    }
}
