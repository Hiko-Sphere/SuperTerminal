import STCore
import SwiftUI

/// A single terminal, with its connection state, prompts and accessory keys.
struct TerminalView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let session: TerminalSession

    @State private var promptText = ""
    @State private var showsControlRow = false

    private var theme: TerminalTheme {
        container.settings.theme(for: colorScheme == .dark, hostOverride: session.host.themeID)
    }

    var body: some View {
        ZStack {
            theme.background.swiftUIColor.ignoresSafeArea()

            VStack(spacing: 0) {
                TerminalScreenView(
                    session: session,
                    theme: theme,
                    fontSize: container.settings.fontSize,
                    blinkCursor: container.settings.cursorBlink
                )
                .accessibilityLabel("Terminal for \(session.host.name)")
                .accessibilityValue(session.screen.visibleText)

                if session.scrollbackOffset > 0 {
                    scrollbackBanner
                }

                // The accessory row is the only way to send Escape, Tab or Control on a
                // phone. It sits above the keyboard rather than inside it so it is
                // reachable whether or not a hardware keyboard is attached.
                if horizontalSizeClass == .compact || showsControlRow {
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
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
                    message: reason ?? "Disconnected.",
                    recoverySuggestion: "Reconnect to continue where you left off."
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
            Label("Scrolled back \(session.scrollbackOffset) lines · Jump to bottom", systemImage: "arrow.down.to.line")
                .font(DesignTokens.Typography.caption)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .frame(maxWidth: .infinity)
        }
        .background(.thinMaterial)
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
                Button("Reconnect", systemImage: "arrow.clockwise") {
                    Task { await session.reconnect() }
                }
                Button("Disconnect", systemImage: "bolt.slash") {
                    Task { await session.disconnect() }
                }
                Divider()
                Toggle("Show Key Row", isOn: $showsControlRow)
            } label: {
                Label("Session", systemImage: "ellipsis.circle")
            }
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

            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
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
