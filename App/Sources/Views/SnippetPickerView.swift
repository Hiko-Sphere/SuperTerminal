import SwiftUI

/// Choose a snippet, or a command from history, to insert into the terminal.
///
/// Insert rather than run, unless the snippet says otherwise. On a phone the difference
/// matters: a mis-tap that inserts text is a nuisance, and one that runs a command may
/// not be.
struct SnippetPickerView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    let session: TerminalSession

    @State private var searchText = ""
    @State private var editingSnippet: Snippet?
    @State private var isCreating = false
    @State private var scope: Scope = .snippets

    private enum Scope: String, CaseIterable, Identifiable {
        case snippets = "Snippets"
        case history = "History"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch scope {
                case .snippets: snippetList
                case .history: historyList
                }
            }
            .searchable(text: $searchText, prompt: scope == .snippets ? "Search snippets" : "Search history")
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Source", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if scope == .snippets {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New snippet", systemImage: "plus") { isCreating = true }
                    }
                }
            }
            .sheet(isPresented: $isCreating) { SnippetEditorView(snippet: nil) }
            .sheet(item: $editingSnippet) { SnippetEditorView(snippet: $0) }
        }
    }

    private var snippetList: some View {
        List {
            if container.snippetStore.snippets.isEmpty {
                ContentUnavailableView {
                    Label("No snippets yet", systemImage: "text.badge.plus")
                } description: {
                    Text("Save the commands you run often so you do not have to type them on a phone keyboard.")
                } actions: {
                    Button("Add a starter set") { container.snippetStore.installStarterSet() }
                    Button("Create one") { isCreating = true }
                }
            }

            ForEach(filteredSnippets) { snippet in
                Button {
                    insert(snippet)
                } label: {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        HStack {
                            Text(snippet.name)
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(DesignTokens.Color.label)
                            if snippet.runsImmediately {
                                Image(systemName: "return")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundStyle(DesignTokens.Color.warning)
                                    .accessibilityLabel("Runs immediately")
                            }
                        }
                        Text(snippet.command)
                            .font(DesignTokens.Typography.monoCaption)
                            .foregroundStyle(DesignTokens.Color.labelSecondary)
                            .lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        container.snippetStore.remove(snippet)
                    }
                    Button("Edit", systemImage: "pencil") { editingSnippet = snippet }
                        .tint(DesignTokens.Color.info)
                }
            }
        }
    }

    private var historyList: some View {
        List {
            if !container.settings.commandHistoryEnabled {
                ContentUnavailableView {
                    Label("History is off", systemImage: "clock.badge.xmark")
                } description: {
                    Text("Command history is off by default, because a terminal's history is among the most sensitive things a device can hold. Turn it on in Settings if you want it; it stays on this device and can be cleared at any time.")
                }
            } else if filteredHistory.isEmpty {
                ContentUnavailableView(
                    "Nothing recorded yet",
                    systemImage: "clock",
                    description: Text("Commands you run will appear here.")
                )
            }

            ForEach(filteredHistory) { entry in
                Button {
                    Task {
                        await session.send(entry.command)
                        dismiss()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        Text(entry.command)
                            .font(DesignTokens.Typography.monoCaption)
                            .foregroundStyle(DesignTokens.Color.label)
                            .lineLimit(2)
                        Text("\(entry.hostName) · \(entry.timestamp.formatted(date: .abbreviated, time: .shortened))")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Color.labelTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var filteredSnippets: [Snippet] {
        guard !searchText.isEmpty else { return container.snippetStore.snippets }
        let needle = searchText.lowercased()
        return container.snippetStore.snippets.filter {
            $0.name.lowercased().contains(needle) || $0.command.lowercased().contains(needle)
        }
    }

    private var filteredHistory: [HistoryEntry] {
        container.snippetStore.searchHistory(searchText)
    }

    private func insert(_ snippet: Snippet) {
        container.snippetStore.markUsed(snippet)
        Task {
            await session.insert(snippet: snippet)
            dismiss()
        }
    }
}

struct SnippetEditorView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    private let existing: Snippet?
    @State private var name: String
    @State private var command: String
    @State private var runsImmediately: Bool
    @State private var folder: String

    init(snippet: Snippet?) {
        existing = snippet
        _name = State(initialValue: snippet?.name ?? "")
        _command = State(initialValue: snippet?.command ?? "")
        _runsImmediately = State(initialValue: snippet?.runsImmediately ?? false)
        _folder = State(initialValue: snippet?.folder ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Snippet") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Folder (optional)", text: $folder)
                }

                Section {
                    TextEditor(text: $command)
                        .accessibilityIdentifier("Snippet command")
                        .accessibilityLabel("Command")
                        .font(DesignTokens.Typography.monoCaption)
                        .frame(minHeight: 100)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Command")
                }

                Section {
                    Toggle("Press Return automatically", isOn: $runsImmediately)
                } footer: {
                    Text(runsImmediately
                        ? "Tapping this snippet runs it straight away. Leave it off for anything you would want to check first."
                        : "The command is typed into the terminal and waits for you to press Return.")
                }

                if !draft.validationProblems.isEmpty {
                    Section("Before you can save") {
                        ForEach(draft.validationProblems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.circle")
                                .font(DesignTokens.Typography.callout)
                                .foregroundStyle(DesignTokens.Color.warning)
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Snippet" : "Edit Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if existing == nil {
                            container.snippetStore.add(draft)
                        } else {
                            container.snippetStore.update(draft)
                        }
                        dismiss()
                    }
                    .disabled(!draft.validationProblems.isEmpty)
                }
            }
        }
    }

    private var draft: Snippet {
        Snippet(
            id: existing?.id ?? UUID(),
            name: name,
            command: command,
            runsImmediately: runsImmediately,
            folder: folder.isEmpty ? nil : folder,
            createdAt: existing?.createdAt ?? Date(),
            useCount: existing?.useCount ?? 0,
            lastUsed: existing?.lastUsed
        )
    }
}

/// The snippet library, reached from Settings rather than from a session.
///
/// Same data as the picker, but without a session to insert into — so it manages rather
/// than chooses.
struct SnippetLibraryView: View {
    @Environment(AppContainer.self) private var container

    @State private var isCreating = false
    @State private var editingSnippet: Snippet?

    var body: some View {
        List {
            if container.snippetStore.snippets.isEmpty {
                ContentUnavailableView {
                    Label("No snippets yet", systemImage: "text.badge.plus")
                } description: {
                    Text("Save the commands you run often. They are available from any session's Snippets menu.")
                } actions: {
                    Button("Add a starter set") { container.snippetStore.installStarterSet() }
                    Button("Create one") { isCreating = true }
                }
            }

            ForEach(container.snippetStore.snippets) { snippet in
                Button {
                    editingSnippet = snippet
                } label: {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        HStack {
                            Text(snippet.name).foregroundStyle(DesignTokens.Color.label)
                            if snippet.runsImmediately {
                                Image(systemName: "return")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundStyle(DesignTokens.Color.warning)
                                    .accessibilityLabel("Runs immediately")
                            }
                            Spacer()
                            if snippet.useCount > 0 {
                                Text("\(snippet.useCount)×")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundStyle(DesignTokens.Color.labelTertiary)
                            }
                        }
                        Text(snippet.command)
                            .font(DesignTokens.Typography.monoCaption)
                            .foregroundStyle(DesignTokens.Color.labelSecondary)
                            .lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        container.snippetStore.remove(snippet)
                    }
                }
            }
        }
        .navigationTitle("Snippets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New snippet", systemImage: "plus") { isCreating = true }
            }
        }
        .sheet(isPresented: $isCreating) { SnippetEditorView(snippet: nil) }
        .sheet(item: $editingSnippet) { SnippetEditorView(snippet: $0) }
    }
}
