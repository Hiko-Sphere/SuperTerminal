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
    /// Called after a remote screen is opened (D-022), for the same reason.
    let onOpenScreen: (VNCSession) -> Void

    @State private var searchText = ""
    @State private var editingHost: Host?
    @State private var editingScreen: ScreenConnection?


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
                            scene.selectedScreenID = nil
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

            if !container.screens.sessions.isEmpty {
                Section("Open screens") {
                    ForEach(container.screens.sessions) { screen in
                        Button {
                            scene.selectedSessionID = nil
                            scene.selectedScreenID = screen.id
                            onOpenScreen(screen)
                        } label: {
                            ScreenRow(screen: screen)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("open-screen")
                        .swipeActions {
                            Button("Close", systemImage: "xmark", role: .destructive) {
                                container.screens.close(screen)
                            }
                        }
                    }
                }
            }

            if !filteredScreens.isEmpty || !container.screenStore.screens.isEmpty {
                Section("Screens") {
                    ForEach(filteredScreens) { screen in
                        savedScreenRow(screen)
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
                                ? "Add a server to get started. Apex Terminal supports plain SSH and servers published through Cloudflare Tunnel, and remote screens over VNC."
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
        .navigationTitle("Apex Terminal")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Two kinds of connection, so the button asks which (D-027). A menu rather
                // than a picker inside one editor: the two have almost no fields in common.
                Menu {
                    Button("New Connection", systemImage: "terminal") { scene.isCreatingConnection = true }
                    Button("New Screen", systemImage: "display") { scene.isCreatingScreen = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityIdentifier("add-connection")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { scene.isShowingSettings = true }
                    .accessibilityIdentifier("settings-open")
            }
        }
        .sheet(isPresented: creatingBinding) {
            HostEditorView(host: nil)
        }
        .sheet(isPresented: creatingScreenBinding) {
            ScreenEditorView(screen: nil)
        }
        .sheet(item: $editingHost) { host in
            HostEditorView(host: host)
        }
        .sheet(item: $editingScreen) { screen in
            ScreenEditorView(screen: screen)
        }
        .sheet(isPresented: settingsBinding) {
            SettingsView()
        }
    }

    /// One connection row. Kept out of the list body so the type checker has one row's
    /// worth of expression to solve, not the whole list's.
    private func hostRow(_ host: Host) -> some View {
        HostRow(
            host: host,
            onEdit: { editingHost = host },
            onDelete: { delete(host) },
            onOpenScreen: nil
        ) {
            let session = container.sessionManager.open(host)
            container.hostStore.markConnected(host)
            scene.selectedScreenID = nil
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

    /// One saved screen (D-027), which opens the same way a connection does.
    private func savedScreenRow(_ screen: ScreenConnection) -> some View {
        SavedScreenRow(
            screen: screen,
            sshHostName: screen.route.sshHostID.flatMap { id in
                container.hostStore.hosts.first { $0.id == id }?.name
            },
            onEdit: { editingScreen = screen },
            onDelete: { delete(screen) }
        ) {
            openScreen(screen)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { delete(screen) }
            Button("Edit", systemImage: "pencil") { editingScreen = screen }
                .tint(DesignTokens.Color.info)
        }
    }

    /// Opens a saved screen and shows it, the way `hostRow` shows a terminal. The SSH
    /// connection its route names is resolved here, so a route naming one that has been
    /// deleted arrives as `nil` and the session says so.
    private func openScreen(_ screen: ScreenConnection) {
        let host = screen.route.sshHostID.flatMap { id in
            container.hostStore.hosts.first { $0.id == id }
        }
        let session = container.screens.open(screen, through: host)
        container.screenStore.markConnected(screen)
        scene.selectedSessionID = nil
        scene.selectedScreenID = session.id
        onOpenScreen(session)
    }

    /// The Keychain item belongs to the screen; leaving it behind would keep a password
    /// nothing can use.
    private func delete(_ screen: ScreenConnection) {
        try? container.vault.deleteVNCPassword(screenID: screen.id)
        try? container.vault.deleteServiceToken(screenID: screen.id)
        container.screenStore.remove(screen)
    }

    /// The Keychain items belong to the connection; leaving them behind would keep a
    /// password or service token nothing can use.
    private func delete(_ host: Host) {
        try? container.vault.deletePassword(hostID: host.id)
        try? container.vault.deleteServiceToken(hostID: host.id)
        container.hostStore.remove(host)
    }

    private var filteredScreens: [ScreenConnection] {
        guard !searchText.isEmpty else { return container.screenStore.screens }
        let needle = searchText.lowercased()
        return container.screenStore.screens.filter {
            $0.name.lowercased().contains(needle) || $0.address.lowercased().contains(needle)
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

    private var creatingScreenBinding: Binding<Bool> {
        Binding(
            get: { scene.isCreatingScreen },
            set: { scene.isCreatingScreen = $0 }
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
    /// Present when the connection has screen sharing set up (D-022).
    let onOpenScreen: (() -> Void)?
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
            if let onOpenScreen {
                Button("Open Screen", systemImage: "display", action: onOpenScreen)
            }
            Button("Edit Connection", systemImage: "pencil", action: onEdit)
                .accessibilityIdentifier("host-edit")
            Button("Delete Connection", systemImage: "trash", role: .destructive, action: onDelete)
        }
        // `.combine`, not `.ignore`: with children ignored the button underneath is no
        // longer the element hit-testing resolves to, and XCUITest treats the row as not
        // hittable at all. The explicit label below still wins for VoiceOver.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(host.name), \(detail)")
        .accessibilityHint("Opens a terminal session")
        .accessibilityIdentifier("host-row")
    }

    /// The platform's own symbol once it is known; the transport's until then, because a
    /// Cloudflare connection is worth telling apart before the server has said anything.
    private var icon: some View {
        Image(systemName: host.effectivePlatform?.systemImage
            ?? (host.transport.isCloudflare ? "point.3.connected.trianglepath.dotted" : "server.rack"))
            .foregroundStyle(host.transport.isCloudflare ? DesignTokens.Color.info : DesignTokens.Color.labelSecondary)
    }

    /// "macOS · user@host" once the platform is known, from the server or by hand.
    private var detail: String {
        if let platform = host.effectivePlatform { return "\(platform.title) · \(host.subtitle)" }
        return host.subtitle
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(host.name)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Color.label)
            Text(detail)
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

/// An open remote screen (D-022), styled as the session rows are.
private struct ScreenRow: View {
    let screen: VNCSession

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Image(systemName: "display")
                .foregroundStyle(DesignTokens.Color.labelSecondary)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(screen.displayName)
                    .font(DesignTokens.Typography.body)
                Text(statusText)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
        }
        .accessibilityLabel("\(screen.displayName), \(statusText)")
    }

    private var statusColor: Color {
        switch screen.state {
        case .connected: DesignTokens.Color.success
        case .connecting, .awaitingUser: DesignTokens.Color.warning
        case .failed: DesignTokens.Color.danger
        case .idle, .disconnected: DesignTokens.Color.labelTertiary
        }
    }

    private var statusText: String {
        switch screen.state {
        case .idle: String(localized: "Idle")
        case let .connecting(step): step
        case .awaitingUser: String(localized: "Waiting for you")
        case .connected: String(localized: "Screen sharing")
        case .disconnected: String(localized: "Disconnected")
        case let .failed(error): error.message
        }
    }
}

/// A saved screen (D-027): where it is, and how it gets there.
private struct SavedScreenRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let screen: ScreenConnection
    /// The name of the SSH connection the route names, when it still exists.
    let sshHostName: String?
    let onEdit: () -> Void
    let onDelete: () -> Void
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: "display")
                    .foregroundStyle(DesignTokens.Color.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(screen.name)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Color.label)
                    Text(detail)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
                Spacer(minLength: 0)
                if screen.route.isDirect { directBadge }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit Screen", systemImage: "pencil", action: onEdit)
            Button("Delete Screen", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(screen.name), \(detail)")
        .accessibilityHint("Opens the remote screen")
        .accessibilityIdentifier("screen-row")
    }

    /// "10.0.0.2:5901 through Build box", or the reason it cannot connect.
    private var detail: String {
        switch screen.route {
        case .direct:
            return screen.endpoint
        case .cloudflare:
            return String(localized: "\(screen.endpoint) through Cloudflare")
        case .throughSSH:
            guard let sshHostName else { return String(localized: "SSH connection missing") }
            return String(localized: "\(screen.endpoint) through \(sshHostName)")
        }
    }

    /// Said plainly, because a direct VNC connection is not encrypted.
    private var directBadge: some View {
        Text("Direct")
            .font(DesignTokens.Typography.caption)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .background(Capsule().fill(DesignTokens.Color.warning.opacity(0.15)))
            .foregroundStyle(DesignTokens.Color.warning)
    }
}
