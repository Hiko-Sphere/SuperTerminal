import SwiftUI

/// The list of saved connections, with any open sessions surfaced alongside.
struct HostListView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Called after a session is opened, so a stack-based layout can push to it.
    let onOpen: (TerminalSession) -> Void

    @State private var searchText = ""
    @State private var editingHost: Host?
    @State private var isCreating = false
    @State private var showsSettings = false

    var body: some View {
        List(selection: selectionBinding) {
            if !container.sessionManager.sessions.isEmpty {
                Section("Open sessions") {
                    ForEach(container.sessionManager.sessions) { session in
                        Button {
                            container.sessionManager.selectedSessionID = session.id
                            onOpen(session)
                        } label: {
                            SessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                            .tag(session.id)
                            .swipeActions {
                                Button("Close", systemImage: "xmark", role: .destructive) {
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
                            Button("Add Connection") { isCreating = true }
                        }
                    }
                }

                ForEach(filteredHosts) { host in
                    HostRow(host: host) {
                        let session = container.sessionManager.open(host)
                        container.hostStore.markConnected(host)
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
                Button("New Connection", systemImage: "plus") { isCreating = true }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            }
        }
        .sheet(isPresented: $isCreating) {
            HostEditorView(host: nil)
        }
        .sheet(item: $editingHost) { host in
            HostEditorView(host: host)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stNewConnectionRequested)) { _ in
            isCreating = true
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

    private var selectionBinding: Binding<TerminalSession.ID?> {
        Binding(
            get: { container.sessionManager.selectedSessionID },
            set: { container.sessionManager.selectedSessionID = $0 }
        )
    }
}

private struct HostRow: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let host: Host
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: host.transport.isCloudflare ? "point.3.connected.trianglepath.dotted" : "server.rack")
                    .foregroundStyle(host.transport.isCloudflare ? DesignTokens.Color.info : DesignTokens.Color.labelSecondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(host.name)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Color.label)
                    Text(host.subtitle)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .lineLimit(1)
                }

                Spacer()

                if host.transport.isCloudflare {
                    Text("Access")
                        .font(DesignTokens.Typography.caption)
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .padding(.vertical, DesignTokens.Spacing.xxs)
                        .background(
                            Capsule().fill(DesignTokens.Color.info.opacity(0.15))
                        )
                        .foregroundStyle(DesignTokens.Color.info)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(host.name), \(host.subtitle)")
        .accessibilityHint("Opens a terminal session")
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
