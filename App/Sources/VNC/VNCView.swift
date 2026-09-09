import STVNC
import SwiftUI

/// A remote screen (D-022): the framebuffer, a key row for what touch cannot type, and
/// the connection's state while it is not yet — or no longer — showing anything.
struct VNCView: View {
    @Environment(\.paneContributesToolbar) private var paneContributesToolbar
    @Environment(AppContainer.self) private var container
    let session: VNCSession

    /// The on-screen keyboard, which is a choice. The screen holds the hardware keyboard
    /// whenever it is showing, which is not (D-029).
    @State private var showsSoftwareKeyboard = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var zoomResetToken = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VNCScreenView(
                session: session,
                image: session.image,
                desktopSize: session.desktopSize,
                desktopName: session.desktopName,
                showsSoftwareKeyboard: showsSoftwareKeyboard,
                wantsKeyboard: wantsKeyboard,
                zoomResetToken: zoomResetToken,
                onHaptic: { container.haptics.play($0) }
            )
            .ignoresSafeArea(.container, edges: .horizontal)
            stateOverlay
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if session.isConnected {
                VNCKeyRow(session: session)
            }
        }
        .overlay(alignment: .top) { remoteClipboardBanner }
        .navigationTitle(session.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(item: promptBinding) { prompt in
            PromptSheet(prompt: prompt) { session.resolvePrompt($0) }
        }
        .task(id: session.id) {
            if case .idle = session.state { await session.connect() }
        }
        .onChange(of: session.isConnected) { _, connected in
            if !connected { showsSoftwareKeyboard = false }
        }
    }

    /// Whether the screen should be holding the keyboard: it is connected, the app is in
    /// front and unlocked, and no sheet is over it.
    private var wantsKeyboard: Bool {
        session.isConnected
            && scenePhase == .active
            && !container.appLock.isLocked
            && promptBinding.wrappedValue == nil
    }

    @ViewBuilder private var stateOverlay: some View {
        switch session.state {
        case let .connecting(step):
            VStack(spacing: DesignTokens.Spacing.md) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(step)
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(DesignTokens.Spacing.xl)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
            .accessibilityIdentifier("vnc-connecting")
        case .awaitingUser:
            ProgressView().tint(.white)
        case let .failed(error):
            ConnectionErrorView(error: error) { session.retry() }
                .padding()
        case let .disconnected(reason):
            EmptyStateView(
                title: String(localized: "Screen closed"),
                message: reason ?? String(localized: "The screen sharing session has ended."),
                systemImage: "display.trianglebadge.exclamationmark",
                action: (String(localized: "Reconnect"), { session.retry() })
            )
            .background(DesignTokens.Color.surface)
        case .idle, .connected:
            EmptyView()
        }
    }

    /// The remote copied something. Offered, because the user's clipboard is theirs.
    @ViewBuilder private var remoteClipboardBanner: some View {
        if let text = session.remoteClipboard {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: "doc.on.clipboard")
                Text("The remote copied text")
                    .font(DesignTokens.Typography.callout)
                Spacer(minLength: 0)
                Button(String(localized: "Copy")) {
                    Clipboard.copy(text, expiringAfter: container.settings.clipboardExpirySeconds)
                    _ = session.takeRemoteClipboard()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(String(localized: "Dismiss"), systemImage: "xmark") { _ = session.takeRemoteClipboard() }
                    .labelStyle(.iconOnly)
            }
            .padding(DesignTokens.Spacing.md)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
            .padding(DesignTokens.Spacing.md)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("vnc-remote-clipboard")
        }
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
        // Empty in a pane that is not the focused one, where the bar is shared (D-056).
        if paneContributesToolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(showsSoftwareKeyboard ? String(localized: "Hide Keyboard") : String(localized: "Keyboard"),
                       systemImage: showsSoftwareKeyboard ? "keyboard.chevron.compact.down" : "keyboard") {
                    showsSoftwareKeyboard.toggle()
                }
                .disabled(!session.isConnected)
                .accessibilityIdentifier("vnc-keyboard")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Menu(String(localized: "Send Keys"), systemImage: "command") {
                            Button("Ctrl+Alt+Del") { session.chord([.control, .alt], VNCKeysym.delete) }
                            Button("Alt+Tab") { session.chord([.alt], VNCKeysym.tab) }
                            Button("⌘+Tab (Super+Tab)") { session.chord([.superKey], VNCKeysym.tab) }
                            Button("Ctrl+C") { session.chord([.control], VNCKeysym.forCharacter("c")) }
                            Button("Escape") { session.press(VNCKeysym.escape) }
                        }
                        .disabled(!session.isConnected)
                        Toggle(String(localized: "Send ⌘ to Remote"), systemImage: "command.square", isOn: commandKeyBinding)
                        Button(String(localized: "Paste to Remote Clipboard"), systemImage: "doc.on.clipboard") {
                            if let text = UIPasteboard.general.string { session.sendClipboard(text) }
                        }
                        .disabled(!session.isConnected)
                        Button(String(localized: "Fit to Screen"), systemImage: "arrow.down.right.and.arrow.up.left") {
                            zoomResetToken += 1
                        }
                    }
                    Section {
                        if session.isConnected {
                            Button(String(localized: "Disconnect"), systemImage: "bolt.slash", role: .destructive) {
                                Task { await session.disconnect() }
                            }
                        } else {
                            Button(String(localized: "Reconnect"), systemImage: "arrow.clockwise") { session.retry() }
                        }
                        Button(String(localized: "Close Screen"), systemImage: "xmark", role: .destructive) {
                            container.screens.close(session)
                        }
                    }
                } label: {
                    Label(String(localized: "Screen"), systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("vnc-menu")
            }
        }
    }

    private var commandKeyBinding: Binding<Bool> {
        Binding(get: { session.sendsCommandKey }, set: { session.sendsCommandKey = $0 })
    }
}

/// Keys a touch keyboard has no way to send, plus modifiers that latch for the next key.
struct VNCKeyRow: View {
    let session: VNCSession

    private struct Key: Identifiable {
        let id: String
        let title: String
        let keysym: UInt32
    }

    private static let keys: [Key] = [
        Key(id: "escape", title: "esc", keysym: VNCKeysym.escape),
        Key(id: "tab", title: "tab", keysym: VNCKeysym.tab),
        Key(id: "up", title: "↑", keysym: VNCKeysym.up),
        Key(id: "down", title: "↓", keysym: VNCKeysym.down),
        Key(id: "left", title: "←", keysym: VNCKeysym.left),
        Key(id: "right", title: "→", keysym: VNCKeysym.right),
        Key(id: "home", title: "home", keysym: VNCKeysym.home),
        Key(id: "end", title: "end", keysym: VNCKeysym.end),
        Key(id: "pageUp", title: "pgup", keysym: VNCKeysym.pageUp),
        Key(id: "pageDown", title: "pgdn", keysym: VNCKeysym.pageDown),
        Key(id: "delete", title: "del", keysym: VNCKeysym.delete),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                modifierKey("ctrl", .control)
                modifierKey("alt", .alt)
                modifierKey("shift", .shift)
                modifierKey("⌘", .superKey)
                Divider().frame(height: 20)
                ForEach(Self.keys) { key in
                    Button(key.title) { session.press(key.keysym) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("vnc-key-\(key.id)")
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
        .background(.bar)
        .accessibilityIdentifier("vnc-key-row")
    }

    private func modifierKey(_ title: String, _ modifier: VNCSession.Modifiers) -> some View {
        let latched = session.latchedModifiers.contains(modifier)
        return Button(title) {
            if latched { session.latchedModifiers.remove(modifier) } else { session.latchedModifiers.insert(modifier) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(latched ? DesignTokens.Color.accent : nil)
        .accessibilityIdentifier("vnc-modifier-\(title)")
        .accessibilityValue(latched ? String(localized: "latched") : "")
    }
}
