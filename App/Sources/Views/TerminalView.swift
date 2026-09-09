import STCore
import SwiftUI

/// A single terminal, with its connection state, prompts and accessory keys.
struct TerminalView: View {
    @Environment(AppContainer.self) private var container
    @Environment(SceneState.self) private var scene
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let session: TerminalSession

    @State private var isSearching = false
    @State private var showsSnippets = false
    @State private var showsForwards = false
    @State private var searchQuery = ""
    @State private var searchCaseSensitive = false

    private var theme: TerminalTheme {
        TerminalThemeResolver(settings: container.settings).theme(
            colorScheme: colorScheme,
            differentiateWithoutColor: differentiateWithoutColor,
            increaseContrast: colorSchemeContrast == .increased,
            hostOverride: session.host.themeID
        )
    }

    /// The key row is a preference rather than per-session state: someone who turns it
    /// off because they have a hardware keyboard means it for every session, and having
    /// it come back on the next connection would be a bug they have to fix repeatedly.
    /// The assistant sheet is scene state so ⌘⇧A and the menu open the same sheet (D-020).
    private var assistantBinding: Binding<Bool> {
        Binding(
            get: { scene.isShowingAssistant },
            set: { scene.isShowingAssistant = $0 }
        )
    }

    private var keyRowBinding: Binding<Bool> {
        Binding(
            get: { container.settings.keyRowVisible },
            set: { visible in
                container.settings.keyRowVisible = visible
                // A Control armed from the row and then hidden would eat the next
                // character typed, minutes later, with nothing on screen to explain it.
                if !visible { session.controlLatched = false }
            }
        )
    }

    /// Whether this window is the one displaying the session.
    ///
    /// A session shown in two windows would be told two different sizes, and the remote
    /// program would be resized back and forth between them. Only the window holding the
    /// claim draws the grid and reports its geometry.
    private var isDisplaying: Bool {
        container.sessionManager.owner(ofSessionWithID: session.id) == scene.id
    }

    /// Whether the terminal should be holding the keyboard (D-025): this window is showing
    /// the session, the app is in front and unlocked, and nothing is covering the grid.
    /// Every term is something that takes first-responder status away and never returns it.
    private var wantsKeyboard: Bool {
        isDisplaying
            && scenePhase == .active
            && !container.appLock.isLocked
            && !isSearching
            && !showsSnippets
            && !scene.isShowingPalette
            && !scene.isShowingSettings
            && !scene.isShowingAssistant
            && !scene.isCreatingConnection
            && promptBinding.wrappedValue == nil
            && session.pendingLink == nil
            && session.pendingPaste == nil
    }

    var body: some View {
        terminal
            .animation(
                DesignTokens.Motion.respectingReduceMotion(
                    DesignTokens.Motion.emphasised,
                    reduceMotion: reduceMotion
                ),
                value: session.reconnection
            )
    }

    @ViewBuilder
    private var terminal: some View {
        if isDisplaying {
            connectedTerminal
        } else {
            EmptyStateView(
                title: String(localized: "Open in another window"),
                message: String(localized: "\(session.host.name) is showing in a different window. The connection is still running."),
                systemImage: "macwindow.on.rectangle",
                action: (
                    title: String(localized: "Show it here"),
                    perform: {
                        container.sessionManager.claimDisplay(ofSessionWithID: session.id, by: scene.id)
                    }
                )
            )
        }
    }

    private var connectedTerminal: some View {
        ZStack {
            theme.background.swiftUIColor.ignoresSafeArea()

            VStack(spacing: 0) {
                if let reconnection = session.reconnection {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        ReconnectionBanner(
                            reconnection: reconnection,
                            interface: container.reachability.interface,
                            onRetryNow: { session.retryNow() },
                            onStop: { session.cancelAutomaticReconnection() }
                        )
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if isSearching {
                    FindBar(
                        query: $searchQuery,
                        caseSensitive: $searchCaseSensitive,
                        matchCount: session.searchMatches.count,
                        focusedIndex: session.focusedMatchIndex,
                        onSubmit: { session.search(for: searchQuery, caseSensitive: searchCaseSensitive) },
                        onNext: { session.focusNextMatch() },
                        onPrevious: { session.focusNextMatch(reverse: true) },
                        onClose: {
                            session.clearSearch()
                            isSearching = false
                            searchQuery = ""
                        }
                    )
                }

                TerminalScreenView(
                    session: session,
                    theme: theme,
                    fontSize: container.settings.fontSize,
                    blinkCursor: container.settings.cursorBlink,
                    confirmMultilinePaste: container.settings.confirmMultilinePaste,
                    onCommandPalette: { scene.isShowingPalette = true },
                    onHaptic: { container.haptics.play($0) },
                    onCopy: { Clipboard.copy($0, expiringAfter: container.settings.clipboardExpirySeconds) },
                    onFind: { isSearching = true },
                    onFontSizeChange: { size in
                        // Persisted, because a size chosen by pinching is a preference —
                        // having it snap back on the next session would make the gesture
                        // feel broken rather than temporary.
                        container.settings.fontSize = Double(size)
                    },
                    wantsKeyboard: wantsKeyboard
                )
                .accessibilityElement(children: .ignore)
                // An identifier as well as a label: the label is translated, and an
                // automated run has to find the grid in every language the app ships in.
                .accessibilityIdentifier("terminal-grid")
                .accessibilityLabel(String(localized: "Terminal for \(session.host.name)"))
                // VoiceOver reads the screen contents, which is the only way the terminal
                // is usable without sight — the grid itself is a drawing, not a view
                // hierarchy, so there is nothing else to announce.
                .accessibilityValue(session.screen.visibleText)
                .accessibilityAddTraits(.updatesFrequently)

                if session.selection != nil {
                    selectionBar
                }

                if session.scrollbackOffset > 0 {
                    scrollbackBanner
                }

                // The accessory row is the only way to send Escape, Tab or Control on a
                // phone. It sits above the keyboard rather than inside it so it is
                // reachable whether or not a hardware keyboard is attached.
                // Shown unless the user has turned it off. The size class used to decide
                // this, which left a full-screen iPad with no Control key at all — and an
                // iPad is as likely to be used without a keyboard as a phone.
                if container.settings.keyRowVisible {
                    AccessoryKeyRow(session: session, theme: theme)
                }
            }

            connectionOverlay
        }
        .navigationTitle(session.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(item: promptBinding) { prompt in
            PromptSheet(session: session, prompt: prompt)
        }
        .sheet(isPresented: assistantBinding) {
            AssistantView(session: session)
                .environment(container)
        }
        .sheet(isPresented: $showsForwards) {
            PortForwardsView(session: session)
        }
        .sheet(isPresented: $showsSnippets) {
            SnippetPickerView(session: session)
        }
        .task(id: session.id) {
            // Snippets, pastes and the accessory keys reach the session without passing
            // through the keyboard's input callback, so history is drained here as well
            // — one place that sees every submitted command, whatever sent it.
            for await command in session.submittedCommandStream {
                container.snippetStore.record(
                    command: command,
                    hostID: session.host.id,
                    hostName: session.host.name
                )
            }
        }
        .confirmationDialog(
            String(localized: "Open this link?"),
            isPresented: linkBinding,
            titleVisibility: .visible
        ) {
            if let link = session.pendingLink, let url = URL(string: link.url) {
                Button(String(localized: "Open")) {
                    session.pendingLink = nil
                    UIApplication.shared.open(url)
                }
            }
            Button(String(localized: "Copy Link")) {
                if let url = session.pendingLink?.url {
                    Clipboard.copy(url, expiringAfter: container.settings.clipboardExpirySeconds)
                }
                session.pendingLink = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { session.pendingLink = nil }
        } message: {
            // The full URL is shown because the point of the confirmation is that the
            // user can read where they are about to be sent.
            Text(session.pendingLink?.url ?? "")
        }
        .confirmationDialog(
            pasteDialogTitle,
            isPresented: pasteBinding,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Paste")) {
                if let pending = session.pendingPaste {
                    Task { await session.paste(pending.text) }
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) { session.cancelPendingPaste() }
        } message: {
            Text(pasteDialogMessage)
        }
    }

    private var linkBinding: Binding<Bool> {
        Binding(
            get: { session.pendingLink != nil },
            set: { if !$0 { session.pendingLink = nil } }
        )
    }

    private var pasteBinding: Binding<Bool> {
        Binding(
            get: { session.pendingPaste != nil },
            set: { if !$0 { session.cancelPendingPaste() } }
        )
    }

    private var pasteDialogTitle: String {
        guard let pending = session.pendingPaste else { return String(localized: "Paste") }
        return String(localized: "Paste \(pending.lineCount) lines?")
    }

    private var pasteDialogMessage: String {
        guard let pending = session.pendingPaste else { return "" }
        return pending.isBracketed
            ? String(localized: "The remote program supports bracketed paste, so the text will be inserted without running it. Check it before pressing Return.")
            : String(localized: "This text contains newlines and the remote program does not support bracketed paste, so each line will run as soon as it arrives.")
    }

    /// Shown while text is selected. A bar rather than a floating menu because on a phone
    /// the menu tends to land under the user's own finger.
    private var selectionBar: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            Button {
                if let text = session.selectedText {
                    Clipboard.copy(text, expiringAfter: container.settings.clipboardExpirySeconds)
                    session.selection = nil
                    container.haptics.play(.textInserted)
                }
            } label: {
                Label(String(localized: "Copy"), systemImage: "doc.on.doc")
            }
            Button {
                session.selection = nil
            } label: {
                Label(String(localized: "Clear"), systemImage: "xmark")
            }
            Spacer()
            if let text = session.selectedText {
                Text(String(localized: "\(text.count) characters"))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
        }
        .font(DesignTokens.Typography.callout)
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .stBarBackground()
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var connectionOverlay: some View {
        switch session.state {
        case let .connecting(step):
            VStack(spacing: DesignTokens.Spacing.md) {
                ProgressView()
                Text(step)
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
            .padding(DesignTokens.Spacing.xl)
            .stOverlayBackground()
            .stCardShadow()
            .transition(.opacity)

        case let .failed(error):
            ConnectionErrorView(error: error) {
                Task { await session.reconnect() }
            }

        case let .disconnected(reason):
            ConnectionErrorView(
                error: STError(
                    category: .network,
                    message: reason ?? String(localized: "Disconnected."),
                    recoverySuggestion: String(localized: "Reconnect to continue where you left off.")
                )
            ) {
                Task { await session.reconnect() }
            }

        case .idle, .connected, .awaitingUser:
            EmptyView()
        }
    }

    private var scrollbackBanner: some View {
        Button {
            session.scrollToBottom()
        } label: {
            Label(String(localized: "Scrolled back \(session.scrollbackOffset) lines · Jump to bottom"), systemImage: "arrow.down.to.line")
                .font(DesignTokens.Typography.caption)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .frame(maxWidth: .infinity)
        }
        .stBarBackground()
        .buttonStyle(.plain)
    }

    private var promptBinding: Binding<TerminalSession.PendingPrompt?> {
        Binding(
            get: {
                if case let .awaitingUser(prompt) = session.state { return prompt }
                return nil
            },
            set: { _ in }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(String(localized: "Reconnect"), systemImage: "arrow.clockwise") {
                    Task { await session.reconnect() }
                }
                Button(String(localized: "Disconnect"), systemImage: "bolt.slash") {
                    Task { await session.disconnect() }
                }
                // No shortcut here: ⌘K is the shell's app-level shortcut (RootView) and the
                // terminal view's own key command; a third SwiftUI registration on this
                // menu item made two ⌘K shortcuts compete in one hierarchy.
                Button(String(localized: "Command Palette…"), systemImage: "command") {
                    scene.isShowingPalette = true
                }
                .accessibilityIdentifier("terminal-menu-palette")
                Button(String(localized: "Snippets…"), systemImage: "text.badge.plus") {
                    showsSnippets = true
                }
                .accessibilityIdentifier("terminal-menu-snippets")
                Button(String(localized: "Assistant…"), systemImage: "sparkles") {
                    scene.isShowingAssistant = true
                }
                Button(String(localized: "Port Forwards…"), systemImage: "arrow.left.arrow.right") {
                    showsForwards = true
                }
                .accessibilityIdentifier("terminal-menu-forwards")
                // Panes have to be reachable without a keyboard: on a touch device the
                // shortcuts do not exist, and a feature only a hardware keyboard can start
                // is a feature most people never find (D-055).
                Button(String(localized: "Split Right"), systemImage: "rectangle.split.2x1") {
                    container.shortcuts.perform(.splitRight)
                }
                .accessibilityIdentifier("terminal-menu-split-right")
                Button(String(localized: "Split Down"), systemImage: "rectangle.split.1x2") {
                    container.shortcuts.perform(.splitDown)
                }
                .accessibilityIdentifier("terminal-menu-split-down")
                if scene.panes.paneCount >= 2 {
                    Button(String(localized: "Close Pane"), systemImage: "rectangle.badge.minus", role: .destructive) {
                        container.shortcuts.perform(.closePane)
                    }
                    .accessibilityIdentifier("terminal-menu-close-pane")
                }
                Divider()
                Button(String(localized: "Find…"), systemImage: "magnifyingglass") {
                    isSearching = true
                }
                // The shortcut stays attached directly to the button, ahead of anything
                // that wraps it: this is the modifier order the ⌘F test was written
                // against, and there is no reason to make it prove itself again.
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityIdentifier("terminal-menu-find")
                Divider()
                Toggle(String(localized: "Show Key Row"), isOn: keyRowBinding)
            } label: {
                Label(String(localized: "Session"), systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("terminal-menu")
        }
    }
}

extension TerminalSession.PendingPrompt: Identifiable {
    public var id: String {
        switch self {
        case let .unknownHostKey(identity, _): "unknown-\(identity.storageKey)"
        case let .changedHostKey(identity, _, _): "changed-\(identity.storageKey)"
        case let .password(username, host): "password-\(username)@\(host)"
        case let .keyPassphrase(name): "passphrase-\(name)"
        case let .username(host): "username-\(host)"
        case let .keyboardInteractive(host, challenge):
            // The prompts are part of the identity: a second round is a different sheet,
            // and one keyed only on the host would not be re-presented for it.
            "kbdi-\(host)-\(challenge.prompts.map(\.prompt).joined(separator: "\u{1F}"))"
        }
    }
}

/// A failure the user can act on, rather than a bare alert.
struct ConnectionErrorView: View {
    let error: STError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Image(systemName: iconName)
                .font(.system(size: 40))
                .foregroundStyle(iconColor)

            Text(error.message)
                .font(DesignTokens.Typography.headline)
                .multilineTextAlignment(.center)

            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .multilineTextAlignment(.center)
            }

            Button(String(localized: "Try Again"), action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(maxWidth: 420)
        .stOverlayBackground()
        .stCardShadow(DesignTokens.Elevation.sheet)
        .padding(DesignTokens.Spacing.xl)
    }

    /// The icon is chosen from the error's category, so the same class of failure always
    /// looks the same wherever it surfaces.
    private var iconName: String {
        switch error.category {
        case .network: "wifi.exclamationmark"
        case .tls, .access: "lock.trianglebadge.exclamationmark"
        case .tunnel: "point.3.connected.trianglepath.dotted"
        case .hostKey: "exclamationmark.shield"
        case .sshAuthentication, .credential: "key.slash"
        case .cancelled: "xmark.circle"
        default: "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch error.category {
        case .hostKey: DesignTokens.Color.danger
        case .cancelled: DesignTokens.Color.labelSecondary
        default: DesignTokens.Color.warning
        }
    }
}
