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
    @State private var editingPermissions: SFTPEntry?
    @State private var sharing: URL?

    /// Whether this browser brings its own navigation stack.
    ///
    /// A sheet needs one; a pane must not have one, because a stack inside a pane pops the
    /// stack the pane is already in — the same thing that made tmux panes on a phone throw
    /// the user back to the connection list (D-059, D-071).
    private let wrapsInItsOwnStack: Bool

    init(session: SFTPSession, wrapsInItsOwnStack: Bool = true) {
        _session = State(initialValue: session)
        self.wrapsInItsOwnStack = wrapsInItsOwnStack
    }

    var body: some View {
        // Split into three: one expression carrying the screen, the file pickers and the
        // dialogs together took the type checker past its budget and failed to compile.
        content
            .modifier(FilePresentations(session: session, quickLookURL: $quickLookURL,
                                        isImporting: $isImporting, showsTransfers: $showsTransfers))
            .modifier(FileDialogs(session: session, renaming: $renaming, renameText: $renameText,
                                  deleting: $deleting, isCreatingFolder: $isCreatingFolder,
                                  newFolderName: $newFolderName))
            .sheet(item: $editingPermissions) { entry in
                FilePermissionsView(entry: entry) { mode in
                    Task { await session.setPermissions(mode, on: entry) }
                }
            }
            .sheet(item: Binding(get: { sharing.map(ShareItem.init) }, set: { if $0 == nil { sharing = nil } })) { item in
                ShareLink(item: item.url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .presentationDetents([.medium])
            }
    }

    @ViewBuilder
    private var content: some View {
        if wrapsInItsOwnStack {
            NavigationStack { browser }
        } else {
            browser
        }
    }

    private var browser: some View {
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
            // Dropping onto the list uploads into the folder on screen. `.item` rather
            // than a narrower type: a file manager that accepts only images is not one.
            .dropDestination(for: URL.self) { urls, _ in
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    session.upload(url)
                }
                showsTransfers = !urls.isEmpty
                return !urls.isEmpty
            }
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
        // Dragging a remote file out has to hand over bytes this device does not have,
        // so the item is a promise: the system asks for the file when something accepts
        // the drop, and that is when it is fetched.
        .draggable(FileDragItem(entry: entry, session: session)) {
            Label(entry.name, systemImage: entry.symbol)
        }
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
            Button("Permissions…", systemImage: "lock") { editingPermissions = entry }
            if !entry.isDirectory {
                Button("Share…", systemImage: "square.and.arrow.up") { share(entry) }
            }
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

    /// Sharing needs the bytes locally, so it is a download that opens the share sheet
    /// when it lands rather than a link to something the system cannot reach.
    private func share(_ entry: SFTPEntry) {
        let destination = FileManager.default.temporaryDirectory
        session.download(entry, to: destination)
        let url = destination.appendingPathComponent(entry.name)
        Task {
            while let transfer = session.transfers.last, !transfer.state.isTerminal {
                try? await Task.sleep(for: .milliseconds(120))
            }
            if FileManager.default.fileExists(atPath: url.path) { sharing = url }
        }
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

/// The pickers and sheets, kept out of the browser's body so one expression does not
/// carry the whole screen (D-043).
private struct FilePresentations: ViewModifier {
    let session: SFTPSession
    @Binding var quickLookURL: URL?
    @Binding var isImporting: Bool
    @Binding var showsTransfers: Bool

    func body(content: Content) -> some View {
        content
            .quickLookPreview($quickLookURL)
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case let .success(urls) = result else { return }
                for url in urls {
                    // A file chosen in Files.app lives outside the sandbox and is reachable
                    // only inside a security scope, which the picker grants for this read.
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    session.upload(url)
                }
            }
            .sheet(isPresented: $showsTransfers) { TransferQueueView(session: session) }
            // The same sheet the terminal raises, for the same decisions: an unknown host
            // key, a password, a key passphrase. Browsing a server is not a lesser act
            // than opening a shell on it and must not skip the checks.
            .sheet(item: Binding(
                get: { session.pendingPrompt },
                set: { if $0 == nil { session.resolvePrompt(.reject) } }
            )) { prompt in
                PromptSheet(prompt: prompt) { session.resolvePrompt($0) }
            }
    }
}

/// The alerts and confirmations.
private struct FileDialogs: ViewModifier {
    let session: SFTPSession
    @Binding var renaming: SFTPEntry?
    @Binding var renameText: String
    @Binding var deleting: SFTPEntry?
    @Binding var isCreatingFolder: Bool
    @Binding var newFolderName: String

    func body(content: Content) -> some View {
        content
            .alert("New Folder", isPresented: $isCreatingFolder) {
                TextField("Name", text: $newFolderName)
                Button("Cancel", role: .cancel) { newFolderName = "" }
                Button("Create") {
                    let name = newFolderName
                    newFolderName = ""
                    Task { await session.makeDirectory(named: name) }
                }
            }
            .alert("Rename", isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    if let entry = renaming { Task { await session.rename(entry, to: renameText) } }
                    renaming = nil
                }
            }
            .confirmationDialog(
                deleting.map { String(localized: "Delete \($0.name)?") } ?? "",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
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
}

/// A URL made presentable as a sheet item.
private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}
