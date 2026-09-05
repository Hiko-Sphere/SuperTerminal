import SwiftUI

/// The list of saved connections, with any open sessions surfaced alongside.
struct HostListView: View {
    @Environment(AppContainer.self) private var container
    @Environment(SceneState.self) private var scene
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow

    /// Called after a session is opened, so a stack-based layout can push to it.
    let onOpen: (TerminalSession) -> Void

    @State private var searchText = ""
    @State private var editingHost: Host?

    @State private var showsSettings = false

    var body: some View {
        List(selection: selectionBinding) {
            if !container.sessionManager.sessions.isEmpty {
                Section("Open sessions") {
                    ForEach(container.sessionManager.sessions) { session in
                        Button {
                            scene.selectedSessionID = session.id
                            onOpen(session)
                        } label: {
                            // The hit area goes on the label, not on the styled button:
                            // that is what `HostRow` does and what makes a whole row
                            // tappable rather than just the text inside it.
                            SessionRow(session: session)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("open-session")
                            .tag(session.id)
                            .swipeActions {
                                Button("Close", systemImage: "xmark", role: .destructive) {
                                    container.sessionManager.close(session)
                                }
                            }
                            .contextMenu {
                                if supportsMultipleWindows {
                                    Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                                        openWindow(value: session.id)
                                    }
                                }
                                Button("Close Session", systemImage: "xmark", role: .destructive) {
                                    container.sessionManager.close(session)
                                }
                            }
                    }
                }
            }

            Section("Connections") {
                if filteredHosts.isEmpty {
                    ContentUnavailableView {
                        Label(
                            container.hostStore.hosts.isEmpty ? "No connections yet" : "No matches",
                            systemImage: "server.rack"
                        )
                    } description: {
                        Text(
                            container.hostStore.hosts.isEmpty
                                ? "Add a server to get started. SuperTerminal supports plain SSH and servers published through Cloudflare Tunnel."
                                : "Try a different search."
                        )
                    } actions: {
                        if container.hostStore.hosts.isEmpty {
                            Button("Add Connection") { scene.isCreatingConnection = true }
                        }
                    }
                }

                ForEach(filteredHosts) { host in
                    HostRow(host: host) {
                        let session = container.sessionManager.open(host)
                        container.hostStore.markConnected(host)
                        // Selecting is this list's job in both layouts; `onOpen` only
                        // tells a stack-based layout to push. Leaving selection to the
                        // caller meant the iPad detail column never followed a newly
                        // opened session.
                        scene.selectedSessionID = session.id
                        onOpen(session)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            container.hostStore.remove(host)
                        }
                        Button("Edit", systemImage: "pencil") { editingHost = host }
                            .tint(DesignTokens.Color.info)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: "Search connections")
        .navigationTitle("SuperTerminal")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Connection", systemImage: "plus") { scene.isCreatingConnection = true }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            }
        }
        .sheet(isPresented: creatingBinding) {
            HostEditorView(host: nil)
        }
        .sheet(item: $editingHost) { host in
            HostEditorView(host: host)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
        }
    }

    private var filteredHosts: [Host] {
        guard !searchText.isEmpty else { return container.hostStore.hosts }
        let needle = searchText.lowercased()
        return container.hostStore.hosts.filter {
            $0.name.lowercased().contains(needle)
                || $0.hostname.lowercased().contains(needle)
                || $0.username.lowercased().contains(needle)
                || $0.tags.contains { $0.lowercased().contains(needle) }
        }
    }

    private var creatingBinding: Binding<Bool> {
        Binding(
            get: { scene.isCreatingConnection },
            set: { scene.isCreatingConnection = $0 }
        )
    }

    private var selectionBinding: Binding<TerminalSession.ID?> {
        Binding(
            get: { scene.selectedSessionID },
            set: { scene.selectedSessionID = $0 }
        )
    }
}

private struct HostRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let host: Host
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            // At accessibility text sizes the name wraps to several lines, and a
            // side-by-side icon ends up sitting across them. Stacking vertically is the
            // only layout that survives — found by screenshotting the app at
            // AccessibilityXXXL rather than by reading the code.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        icon
                        if host.transport.isCloudflare { accessBadge }
                    }
                    labels
                }
                .contentShape(Rectangle())
            } else {
                HStack(spacing: DesignTokens.Spacing.md) {
                    icon.frame(width: 24)
                    labels
                    Spacer()
                    if host.transport.isCloudflare { accessBadge }
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(host.name), \(host.subtitle)")
        .accessibilityHint("Opens a terminal session")
    }

    private var icon: some View {
        Image(systemName: host.transport.isCloudflare ? "point.3.connected.trianglepath.dotted" : "server.rack")
            .foregroundStyle(host.transport.isCloudflare ? DesignTokens.Color.info : DesignTokens.Color.labelSecondary)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(host.name)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Color.label)
            Text(host.subtitle)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
                // Truncating a hostname at accessibility sizes hides the very thing that
                // tells two connections apart, so it is allowed to wrap there.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        }
    }

    private var accessBadge: some View {
        Text("Access")
            .font(DesignTokens.Typography.caption)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .background(Capsule().fill(DesignTokens.Color.info.opacity(0.15)))
            .foregroundStyle(DesignTokens.Color.info)
    }
}

private struct SessionRow: View {
    let session: TerminalSession

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(session.displayName)
                    .font(DesignTokens.Typography.body)
                Text(statusText)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
        }
        .accessibilityLabel("\(session.displayName), \(statusText)")
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: DesignTokens.Color.success
        case .connecting, .awaitingUser: DesignTokens.Color.warning
        case .failed: DesignTokens.Color.danger
        case .idle, .disconnected: DesignTokens.Color.labelTertiary
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: "Idle"
        case let .connecting(step): step
        case .awaitingUser: "Waiting for you"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case let .failed(error): error.message
        }
    }
}
