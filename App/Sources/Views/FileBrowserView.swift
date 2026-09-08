import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Browsing a server's files (D-042).
///
/// A list rather than a grid: the questions people bring to a remote file browser are
/// "what is here", "how big", "when did it change" and "may I write to it", and a grid
/// answers none of them without a second tap.
struct FileBrowserView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var session: SFTPSession

    @State private var renaming: SFTPEntry?
    @State private var renameText = ""
    @State private var deleting: SFTPEntry?
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var isImporting = false
    @State private var quickLookURL: URL?
    @State private var showsTransfers = false

    init(session: SFTPSession) {
        _session = State(initialValue: session)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case let .connecting(step):
                    ProgressView(step).frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(error):
                    ContentUnavailableView {
                        Label(error.message, systemImage: "exclamationmark.triangle")
                    } description: {
                        if let suggestion = error.recoverySuggestion { Text(suggestion) }
                    } actions: {
                        Button("Try Again") { Task { await session.connect() } }
                    }
                case .ready:
                    listing
                }
            }
            .navigationTitle(session.hostName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task { await session.connect() }
        }
        .quickLookPreview($quickLookURL)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                session.upload(url)
            }
        }
        .sheet(isPresented: $showsTransfers) { TransferQueueView(session: session) }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await session.makeDirectory(named: name) }
            }
        }
        .alert("Rename", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let entry = renaming { Task { await session.rename(entry, to: renameText) } }
                renaming = nil
            }
        }
        .confirmationDialog(
            deleting.map { String(localized: "Delete \($0.name)?") } ?? "",
            isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = deleting { Task { await session.delete(entry) } }
                deleting = nil
            }
        } message: {
            Text(deleting?.isDirectory == true
                 ? "A folder must be empty before it can be deleted."
                 : "This cannot be undone.")
        }
    }

    // MARK: - Listing

    @ViewBuilder
    private var listing: some View {
        VStack(spacing: 0) {
            pathBar
            if let error = session.operationError {
                Label(error.message, systemImage: "exclamationmark.circle")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                    .padding(.bottom, DesignTokens.Spacing.sm)
            }
            List {
                if SFTPEntry.parent(of: session.path) != nil {
                    Button {
                        Task { await session.goUp() }
                    } label: {
                        Label("Up one level", systemImage: "arrow.up.left")
                    }
                    .accessibilityIdentifier("files-up")
                }
                ForEach(session.entries) { entry in
                    row(entry)
                }
            }
            .listStyle(.plain)
            .refreshable { await session.reload() }
            .overlay {
                if session.entries.isEmpty, !session.isLoading {
                    ContentUnavailableView(
                        session.search.isEmpty ? "This folder is empty" : "Nothing matches",
                        systemImage: session.search.isEmpty ? "folder" : "magnifyingglass"
                    )
                }
            }
        }
        .searchable(text: Binding(get: { session.search }, set: { session.search = $0 }), prompt: "Search this folder")
    }

    private func row(_ entry: SFTPEntry) -> some View {
        Button {
            Task { await activate(entry) }
        } label: {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: entry.symbol)
                    .foregroundStyle(entry.isDirectory ? DesignTokens.Color.accent : DesignTokens.Color.labelSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(DesignTokens.Typography.body)
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        if let size = entry.formattedSize { Text(size) }
                        if let modified = entry.modified {
                            Text(modified.formatted(.relative(presentation: .named)))
                        }
                        if let permissions = entry.formattedPermissions {
                            Text(permissions).font(DesignTokens.Typography.monoCaption)
                        }
                    }
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                }
                Spacer()
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DesignTokens.Color.labelTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("file-row")
        // One element, so VoiceOver reads "name, 4 KB, yesterday" rather than making the
        // reader swipe through three fragments of one row.
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = entry } label: { Label("Delete", systemImage: "trash") }
            Button { renaming = entry; renameText = entry.name } label: { Label("Rename", systemImage: "pencil") }
                .tint(DesignTokens.Color.info)
        }
        .contextMenu {
            if !entry.isDirectory {
                Button("Download", systemImage: "arrow.down.circle") { download(entry) }
                Button("Quick Look", systemImage: "eye") { preview(entry) }
            }
            Button("Rename", systemImage: "pencil") { renaming = entry; renameText = entry.name }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = entry }
        }
    }

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(Array(session.pathComponents.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DesignTokens.Color.labelTertiary)
                    }
                    Button(component.name) {
                        Task { await session.navigate(to: component.path) }
                    }
                    .font(DesignTokens.Typography.caption)
                    .disabled(component.path == session.path)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
        .background(DesignTokens.Color.surfaceSecondary)
        .accessibilityIdentifier("files-path")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { Task { await session.disconnect(); dismiss() } }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New Folder", systemImage: "folder.badge.plus") { isCreatingFolder = true }
                Button("Upload…", systemImage: "arrow.up.circle") { isImporting = true }
                Divider()
                Toggle("Show hidden files", isOn: Binding(
                    get: { session.showsHiddenFiles }, set: { session.showsHiddenFiles = $0 }
                ))
                Picker("Sort by", selection: Binding(get: { session.sort }, set: { session.sort = $0 })) {
                    Text("Name").tag(SFTPEntry.Sort.name)
                    Text("Size").tag(SFTPEntry.Sort.size)
                    Text("Date").tag(SFTPEntry.Sort.modified)
                }
                Toggle("Ascending", isOn: Binding(
                    get: { session.sortAscending }, set: { session.sortAscending = $0 }
                ))
                Divider()
                Button("Transfers", systemImage: "arrow.up.arrow.down") { showsTransfers = true }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("files-menu")
        }
    }

    // MARK: - Actions

    private func activate(_ entry: SFTPEntry) async {
        if entry.isDirectory || entry.isSymbolicLink {
            await session.open(entry)
        } else {
            preview(entry)
        }
    }

    private func download(_ entry: SFTPEntry) {
        session.download(entry, to: FileManager.default.temporaryDirectory)
        showsTransfers = true
    }

    /// Quick Look needs a local file, so previewing is a download that opens when it
    /// lands. Shown through the transfer list so a large file does not look like nothing
    /// happening.
    private func preview(_ entry: SFTPEntry) {
        let destination = FileManager.default.temporaryDirectory
        session.download(entry, to: destination)
        let url = destination.appendingPathComponent(entry.name)
        Task {
            while let transfer = session.transfers.last, !transfer.state.isTerminal {
                try? await Task.sleep(for: .milliseconds(120))
            }
            if FileManager.default.fileExists(atPath: url.path) { quickLookURL = url }
        }
    }
}
