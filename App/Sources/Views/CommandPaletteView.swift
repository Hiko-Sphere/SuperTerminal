import STCore
import SwiftUI

/// One thing the palette can do.
struct PaletteItem: Identifiable {
    enum Kind: String {
        case session = "Open sessions"
        case connection = "Connections"
        case snippet = "Snippets"
        case action = "Actions"

        /// What the badge shows. Separate from the raw value because a raw value has to be
        /// a compile-time literal, so it can never carry a translation.
        var displayName: String {
            switch self {
            case .session: return String(localized: "Open sessions")
            case .connection: return String(localized: "Connections")
            case .snippet: return String(localized: "Snippets")
            case .action: return String(localized: "Actions")
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String?
    let systemImage: String
    /// The shortcut that would have done the same thing, shown so the palette teaches them.
    let shortcut: String?
    let perform: () -> Void

    /// What the query is matched against — title and subtitle together, so typing a
    /// hostname finds a connection named after something else.
    var searchable: String {
        guard let subtitle, !subtitle.isEmpty else { return title }
        return "\(title) \(subtitle)"
    }
}

/// Everything the app can do, one keystroke away.
///
/// Modelled on the palettes people already know from their editors, because the muscle
/// memory is the point: ⌘K, three letters, Return. Ranking is what makes that work — with
/// forty things matching `wp`, which one goes first *is* the feature — so it uses real
/// fuzzy scoring rather than a substring filter, and shows which characters matched.
struct CommandPaletteView: View {
    @Environment(AppContainer.self) private var container
    @Environment(SceneState.self) private var scene
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The session the palette was opened from, if any. Actions needing one are only
    /// offered when there is one.
    let session: TerminalSession?
    /// Pushes a session into view on a stack-based layout.
    let onOpen: (TerminalSession) -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
        }
        .background(DesignTokens.Color.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { queryFocused = true }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private var searchField: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DesignTokens.Color.labelTertiary)
            TextField("Search connections, snippets and actions", text: $query)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.body)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($queryFocused)
                .submitLabel(.go)
                .onSubmit(runSelection)
                .accessibilityIdentifier("palette-query")
                // Arrows move the highlight without leaving the field, which is what makes
                // the palette usable from a hardware keyboard at all.
                .onKeyPress(.upArrow) { move(by: -1); return .handled }
                .onKeyPress(.downArrow) { move(by: 1); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
                    .buttonStyle(.plain)
            }
        }
        .padding(DesignTokens.Spacing.lg)
    }

    @ViewBuilder
    private var results: some View {
        let matches = rankedItems
        if matches.isEmpty {
            ContentUnavailableView(
                "Nothing matches",
                systemImage: "magnifyingglass",
                description: Text("Try fewer letters — they do not have to be next to each other.")
            )
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(matches.enumerated()), id: \.element.item.id) { index, match in
                        row(match.item, result: match.result, isSelected: index == selection)
                            .id(match.item.id)
                            .listRowBackground(
                                index == selection
                                    ? DesignTokens.Color.accent.opacity(0.14)
                                    : Color.clear
                            )
                    }
                }
                .listStyle(.plain)
                .onChange(of: selection) { _, new in
                    guard new < matches.count else { return }
                    withAnimation(
                        DesignTokens.Motion.respectingReduceMotion(
                            DesignTokens.Motion.quick,
                            reduceMotion: reduceMotion
                        )
                    ) {
                        proxy.scrollTo(matches[new].item.id, anchor: .center)
                    }
                }
            }
        }
    }

    private func row(_ item: PaletteItem, result: FuzzyMatch.Result, isSelected: Bool) -> some View {
        Button {
            run(item)
        } label: {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: item.systemImage)
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? DesignTokens.Color.accent : DesignTokens.Color.labelSecondary)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(highlighted(item.title, indices: result.matchedIndices))
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Color.label)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Color.labelSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(item.shortcut ?? item.kind.displayName)
                    .font(DesignTokens.Typography.caption.monospaced())
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
                    .padding(.horizontal, DesignTokens.Spacing.xs)
                    .padding(.vertical, DesignTokens.Spacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                            .fill(DesignTokens.Color.surfaceSecondary)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("palette-\(item.id)")
    }

    /// Bolds the characters the query actually matched.
    ///
    /// Without it a fuzzy result looks arbitrary: showing *why* `wpr` found `web-prod` is
    /// what makes the ranking legible rather than magic.
    private func highlighted(_ text: String, indices: [Int]) -> AttributedString {
        var attributed = AttributedString(text)
        let characters = Array(text)
        for index in indices where index < characters.count {
            let start = attributed.index(attributed.startIndex, offsetByCharacters: index)
            let end = attributed.index(start, offsetByCharacters: 1)
            attributed[start ..< end].font = DesignTokens.Typography.body.bold()
            attributed[start ..< end].foregroundColor = DesignTokens.Color.accent
        }
        return attributed
    }

    // MARK: - Behaviour

    private var rankedItems: [(item: PaletteItem, result: FuzzyMatch.Result)] {
        FuzzyMatch.rank(items, query: query) { $0.searchable }
    }

    private func move(by delta: Int) {
        let count = rankedItems.count
        guard count > 0 else { return }
        // Wraps, so holding Down does not stick at the bottom.
        selection = (selection + delta + count) % count
    }

    private func runSelection() {
        let matches = rankedItems
        guard selection < matches.count else { return }
        run(matches[selection].item)
    }

    private func run(_ item: PaletteItem) {
        dismiss()
        item.perform()
    }

    // MARK: - What the palette offers

    private var items: [PaletteItem] {
        var result: [PaletteItem] = []

        for openSession in container.sessionManager.sessions where openSession.id != session?.id {
            result.append(PaletteItem(
                id: "session-\(openSession.id)",
                kind: .session,
                title: openSession.host.name,
                subtitle: openSession.title.isEmpty ? openSession.host.subtitle : openSession.title,
                systemImage: "terminal",
                shortcut: nil,
                perform: {
                    scene.selectedSessionID = openSession.id
                    onOpen(openSession)
                }
            ))
        }

        for host in container.hostStore.hosts {
            result.append(PaletteItem(
                id: "host-\(host.id)",
                kind: .connection,
                title: host.name,
                subtitle: host.subtitle,
                systemImage: host.transport.isCloudflare ? "cloud" : "server.rack",
                shortcut: nil,
                perform: {
                    let opened = container.sessionManager.open(host)
                    container.hostStore.markConnected(host)
                    scene.selectedSessionID = opened.id
                    onOpen(opened)
                }
            ))
        }

        if let session {
            for snippet in container.snippetStore.snippets {
                result.append(PaletteItem(
                    id: "snippet-\(snippet.id)",
                    kind: .snippet,
                    title: snippet.name,
                    subtitle: snippet.command,
                    systemImage: "text.badge.plus",
                    shortcut: nil,
                    perform: {
                        container.snippetStore.markUsed(snippet)
                        Task { await session.insert(snippet: snippet) }
                    }
                ))
            }
        }

        result.append(contentsOf: actions)
        return result
    }

    private var actions: [PaletteItem] {
        var result: [PaletteItem] = [
            PaletteItem(
                id: "action-new",
                kind: .action,
                title: String(localized: "New Connection"),
                subtitle: String(localized: "Add a server"),
                systemImage: "plus",
                shortcut: "⌘N",
                perform: { scene.isCreatingConnection = true }
            ),
        ]

        if let session {
            result.append(PaletteItem(
                id: "action-close",
                kind: .action,
                title: String(localized: "Close Session"),
                subtitle: session.host.name,
                systemImage: "xmark",
                shortcut: "⌘W",
                perform: { container.sessionManager.close(session) }
            ))
            result.append(PaletteItem(
                id: "action-reconnect",
                kind: .action,
                title: String(localized: "Reconnect"),
                subtitle: String(localized: "Starts a new shell on \(session.host.name)"),
                systemImage: "arrow.clockwise",
                shortcut: nil,
                perform: { Task { await session.reconnect() } }
            ))
            result.append(PaletteItem(
                id: "action-clear",
                kind: .action,
                title: String(localized: "Clear Screen"),
                subtitle: String(localized: "Keeps the scrollback"),
                systemImage: "eraser",
                shortcut: nil,
                perform: { Task { await session.send("\u{0C}") } }
            ))
        }

        result.append(PaletteItem(
            id: "action-keyrow",
            kind: .action,
            title: container.settings.keyRowVisible
                ? String(localized: "Hide Key Row")
                : String(localized: "Show Key Row"),
            subtitle: String(localized: "Control, Esc, Tab and the arrows"),
            systemImage: "keyboard",
            shortcut: nil,
            perform: { container.settings.keyRowVisible.toggle() }
        ))

        return result
    }
}
