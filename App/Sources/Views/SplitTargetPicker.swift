import SwiftUI

/// Choosing what goes in a pane (D-074).
///
/// A split screen is a layout, not a duplicate: the other half is very often a *different*
/// server, or one that has not been added yet, or a machine's screen over VNC. This is where
/// that is said. It offers, in the order someone actually reaches for them: what is already
/// open, the connections and screens they have saved, and — for the server that is not in the
/// list yet — the editors, whose result goes straight into the pane.
struct SplitTargetPicker: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let placement: PendingSplit.Placement
    let choose: (SplitTarget) -> Void

    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if !openRows.isEmpty {
                    Section {
                        ForEach(openRows) { row in rowButton(row) }
                    } header: {
                        Text("Already open")
                    } footer: {
                        Text("Showing one of these here moves it into this pane; it is not opened twice.")
                    }
                }

                if !connectionRows.isEmpty {
                    Section("Connections") {
                        ForEach(connectionRows) { row in rowButton(row) }
                    }
                }

                if !screenRows.isEmpty {
                    Section("Screens") {
                        ForEach(screenRows) { row in rowButton(row) }
                    }
                }

                Section {
                    rowButton(Row(
                        target: .addConnection,
                        title: String(localized: "Add a Connection…"),
                        subtitle: String(localized: "A server that is not in the list yet"),
                        symbol: "plus.circle",
                        isOpen: false
                    ))
                    rowButton(Row(
                        target: .addScreen,
                        title: String(localized: "Add a Screen…"),
                        subtitle: String(localized: "A machine whose screen you want to see"),
                        symbol: "plus.rectangle.on.rectangle",
                        isOpen: false
                    ))
                }

                if openRows.isEmpty, connectionRows.isEmpty, screenRows.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // The placement is required: without it an iPad puts the field somewhere the
            // tests — and people — cannot find (D-056).
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("Search connections and screens")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .accessibilityIdentifier("split-target-picker")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.disabled)
    }

    private var title: String {
        switch placement {
        case let .split(axis):
            axis == .horizontal
                ? String(localized: "Split to the Right")
                : String(localized: "Split Below")
        case .replace:
            String(localized: "Show in This Pane")
        }
    }

    // MARK: - Rows

    private struct Row: Identifiable {
        let target: SplitTarget
        let title: String
        let subtitle: String
        let symbol: String
        let isOpen: Bool
        var id: String { target.id }
        /// Named for the tests, and named per *kind* rather than per row: "the picker offers
        /// a way to add a server that is not saved yet" is the claim worth pinning.
        var identifier: String {
            switch target {
            case .addConnection: "split-target-add-connection"
            case .addScreen: "split-target-add-screen"
            default: "split-target-row"
            }
        }
    }

    @ViewBuilder
    private func rowButton(_ row: Row) -> some View {
        Button {
            // The feedback belongs here rather than at the far end: the choice is the
            // moment, and the session it starts may take a second to connect.
            container.haptics.play(.selectionChanged)
            choose(row.target)
            dismiss()
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: row.symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(DesignTokens.Color.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.body)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if row.isOpen {
                    Circle()
                        .fill(DesignTokens.Color.success)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(Text("Open"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(row.identifier)
        .accessibilityLabel(Text(row.subtitle.isEmpty ? row.title : "\(row.title), \(row.subtitle)"))
    }

    /// `user@host:port`, or just the host where the rest is the default — the same line the
    /// connection list shows, so a row means the same thing in both places.
    static func summary(of host: Host) -> String {
        let usesCloudflare = if case .cloudflare = host.transport { true } else { false }
        let port = host.port == (usesCloudflare ? 443 : 22) ? "" : ":\(host.port)"
        let user = host.username.isEmpty ? "" : "\(host.username)@"
        return "\(user)\(host.hostname)\(port)"
    }

    private func matches(_ text: String...) -> Bool {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        return text.contains { $0.localizedStandardContains(query) }
    }

    private var openRows: [Row] {
        var rows: [Row] = []
        for session in container.sessionManager.sessions where matches(session.host.name, session.host.hostname) {
            rows.append(Row(
                target: .openSession(session.id),
                title: session.host.name,
                subtitle: Self.summary(of: session.host),
                symbol: "terminal",
                isOpen: true
            ))
        }
        for session in container.tmux.sessions where matches(session.host.name, session.host.hostname) {
            rows.append(Row(
                target: .openTmuxSession(session.id),
                title: session.host.name,
                subtitle: String(localized: "tmux"),
                symbol: "square.split.bottomrightquarter",
                isOpen: true
            ))
        }
        for screen in container.screens.sessions where matches(screen.displayName) {
            rows.append(Row(
                target: .openScreen(screen.id),
                title: screen.displayName,
                subtitle: String(localized: "Screen"),
                symbol: "display",
                isOpen: true
            ))
        }
        for browser in container.sessionManager.fileSessions where matches(browser.hostName) {
            rows.append(Row(
                target: .openFileBrowser(browser.id),
                title: browser.hostName,
                subtitle: String(localized: "Files"),
                symbol: "folder",
                isOpen: true
            ))
        }
        return rows
    }

    private var connectionRows: [Row] {
        container.hostStore.hosts
            .filter { matches($0.name, $0.hostname, $0.username) }
            .map { host in
                Row(
                    target: host.isUsingTmux ? .newTmuxSession(host.id) : .newSession(host.id),
                    title: host.name,
                    subtitle: Self.summary(of: host),
                    symbol: host.isUsingTmux ? "square.split.bottomrightquarter" : "terminal",
                    isOpen: false
                )
            }
    }

    private var screenRows: [Row] {
        container.screenStore.screens
            .filter { matches($0.name, $0.address) }
            .map { screen in
                Row(
                    target: .newScreen(screen.id),
                    title: screen.name,
                    subtitle: screen.address.isEmpty ? String(localized: "Through the SSH connection") : screen.address,
                    symbol: "display",
                    isOpen: false
                )
            }
    }
}
