import SwiftUI

/// The app's shell.
///
/// A split view on iPad and a stack on iPhone, driven by the size class rather than the
/// idiom — so a Slide Over window on iPad gets the compact layout, which is the right
/// answer, and Stage Manager resizing moves between them live.
struct RootView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
        .onAppear { container.sessionManager.selectedSessionID = container.sessionManager.sessions.first?.id }
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
            // In a split view the detail column follows the selection, so opening a
            // session is all that is needed.
            HostListView { _ in }
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            if let session = container.sessionManager.selectedSession {
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
struct SuperTerminalCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Connection…") {
                NotificationCenter.default.post(name: .stNewConnectionRequested, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Session") {
            Button("Close Session") {
                NotificationCenter.default.post(name: .stCloseSessionRequested, object: nil)
            }
            .keyboardShortcut("w", modifiers: .command)
        }
    }
}

extension Notification.Name {
    static let stNewConnectionRequested = Notification.Name("dev.superterminal.newConnection")
    static let stCloseSessionRequested = Notification.Name("dev.superterminal.closeSession")
}
