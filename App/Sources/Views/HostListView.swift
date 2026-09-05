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


    var body: some View {
        List(selection: selectionBinding) {
            if !resumable.isEmpty, container.sessionManager.sessions.isEmpty {
                Section {
                    Button {
                        reopenPreviousSessions()
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.md) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.title2)
                                .foregroundStyle(DesignTokens.Color.accent)
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                                Text(resumable.count == 1
                                    ? "Reopen \(resumable[0].hostName)"
                                    : "Reopen \(resumable.count) connections")
                                    .font(DesignTokens.Typography.body)
                                    .foregroundStyle(DesignTokens.Color.label)
                                // Honest about what this does. The shells are gone; these
                                // are new connections to the same machines.
                                Text("From last time. These are new sessions — nothing that was running has survived.")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Dismiss", systemImage: "xmark", role: .destructive) {
                            container.restoration.clear()
                        }
                    }
                }
            }

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
                    hostRow(host)
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
                Button("Settings", systemImage: "gearshape") { scene.isShowingSettings = true }
            }
        }
        .sheet(isPresented: creatingBinding) {
            HostEditorView(host: nil)
        }
        .sheet(item: $editingHost) { host in
            HostEditorView(host: host)
        }
        .sheet(isPresented: settingsBinding) {
            SettingsView()
        }
    }

    /// One connection row. Kept out of the list body so the type checker has one row's
    /// worth of expression to solve, not the whole list's.
    private func hostRow(_ host: Host) -> some View {
        HostRow(host: host, onEdit: { editingHost = host }, onDelete: { delete(host) }) {
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
            Button("Delete", systemImage: "trash", role: .destructive) { delete(host) }
            Button("Edit", systemImage: "pencil") { editingHost = host }
                .tint(DesignTokens.Color.info)
        }
    }

    /// The Keychain items belong to the connection; leaving them behind would keep a
    /// password or service token nothing can use.
    private func delete(_ host: Host) {
        try? container.vault.deletePassword(hostID: host.id)
        try? container.vault.deleteServiceToken(hostID: host.id)
        container.hostStore.remove(host)
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

    /// Connections from last time that still exist. A host deleted since then is not
    /// offered, because reopening it is not something the app can do.
    private var resumable: [SessionRestorationStore.RestorableSession] {
        container.restoration.pending.filter { entry in
            container.hostStore.hosts.contains { $0.id == entry.hostID }
        }
    }

    private func reopenPreviousSessions() {
        let entries = resumable
        // Cleared first: if one of these fails to connect the offer should not reappear
        // and invite the user to try the whole set again.
        container.restoration.clear()
        var first: TerminalSession?
        for entry in entries {
            guard let host = container.hostStore.hosts.first(where: { $0.id == entry.hostID }) else { continue }
            let session = container.sessionManager.open(host)
            container.hostStore.markConnected(host)
            if first == nil { first = session }
        }
        if let first {
            scene.selectedSessionID = first.id
            onOpen(first)
        }
    }

    private var settingsBinding: Binding<Bool> {
        Binding(
            get: { scene.isShowingSettings },
            set: { scene.isShowingSettings = $0 }
        )
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
    let onEdit: () -> Void
    let onDelete: () -> Void
    /// Last, so the call site can pass it as the trailing closure.
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
        // On the button itself, as the session rows do: attached outside, the button's own
        // press handling swallowed the long press and the menu never appeared.
        .contextMenu {
            Button("Edit Connection", systemImage: "pencil", action: onEdit)
            Button("Delete Connection", systemImage: "trash", role: .destructive, action: onDelete)
        }
        // `.combine`, not `.ignore`: with children ignored the button underneath is no
        // longer the element hit-testing resolves to, and XCUITest treats the row as not
        // hittable at all. The explicit label below still wins for VoiceOver.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(host.name), \(host.subtitle)")
        .accessibilityHint("Opens a terminal session")
        .accessibilityIdentifier("host-row")
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
        case .idle: String(localized: "Idle")
        case let .connecting(step): step
        case .awaitingUser: String(localized: "Waiting for you")
        case .connected: String(localized: "Connected")
        case .disconnected: String(localized: "Disconnected")
        case let .failed(error): error.message
        }
    }
}
