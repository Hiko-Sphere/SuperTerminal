import STCore
import SwiftUI
import UniformTypeIdentifiers

/// The palettes a person made, and where they are made.
///
/// The app has always been able to *hold* a custom theme — `allThemes` reads them, a backup
/// carries them, and since D-078 they survive a relaunch — but nothing anywhere could create
/// one, so `allThemes` was the three built-ins for every user who has ever run it. This is the
/// missing half.
struct ThemeWorkshopView: View {
    @Environment(AppContainer.self) private var container

    @State private var isImporting = false
    @State private var problem: String?
    @State private var pendingDeletion: TerminalTheme?
    /// The id of a theme just created, pushed straight into the editor: making a theme and
    /// then having to find it in a list is one step too many.
    @State private var editing: String?

    private var library: ThemeLibrary {
        ThemeLibrary(settings: container.settings, hosts: container.hostStore)
    }

    var body: some View {
        List {
            // No "Your themes" section at all while there are none — an empty section is a
            // heading over nothing, and on iPadOS it is worse than that: a section whose only
            // content is unfocusable builds a focus container with no items, and the focus
            // engine asserts on it the moment the form is scrolled. That was a real crash on
            // an iPad, in Settings, from a `ContentUnavailableView` placed inside a `List`
            // section here — reached without ever opening this screen, because a closure-based
            // `NavigationLink` evaluates its destination as soon as the row appears. The empty
            // case is carried by the footer below instead, which is the better design anyway:
            // the section that says what to do is the one to read.
            if !library.custom.isEmpty {
                Section {
                    ForEach(library.custom) { theme in
                        // The destination in place rather than a value pushed onto a stack
                        // this view is only a guest on: `HelpTopicsView` measured exactly that
                        // and documents it — a value-based link resolved against the wrong
                        // stack, and the row simply did not open. Wrapped so it is still built
                        // only when it is shown, since an eagerly built destination is what
                        // crashed the focus engine to begin with.
                        NavigationLink {
                            LazyDestination { ThemeEditorView(themeID: theme.id) }
                        } label: {
                            row(theme)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                pendingDeletion = theme
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Your themes")
                } footer: {
                    Text("A theme stays on this device and travels in a backup. It does not sync: a connection set to a theme the other device does not have opens in the default theme there, and says so.")
                }
            }

            Section {
                ForEach(TerminalTheme.builtIn) { theme in
                    Button {
                        start(from: theme)
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.md) {
                            row(theme)
                            Image(systemName: "plus.square.on.square")
                                .foregroundStyle(DesignTokens.Color.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("theme-start-from-\(theme.id)")
                }
            } header: {
                Text("Start from")
            } footer: {
                if library.custom.isEmpty {
                    Text("You have no themes of your own yet. Pick one of these to copy and change, or bring in a .itermcolors file exported from a terminal on your computer.")
                        .accessibilityIdentifier("theme-workshop-empty")
                } else {
                    Text("Copies the palette so you can change it. The built-in ones themselves are never altered.")
                }
            }

            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(DesignTokens.Typography.callout)
                        .foregroundStyle(DesignTokens.Color.danger)
                        .accessibilityIdentifier("theme-problem")
                }
            }
        }
        .accessibilityIdentifier("theme-workshop-list")
        .navigationTitle("Themes")
        // One destination for both ways in — a tap on a row and a theme just made — so the
        // Making a theme opens it straight away — finding it again in a list is one step too
        // many. Only this one, driven by a binding: rows push their destination directly, so
        // nothing here registers a destination *type* on a stack it is only a guest on.
        .navigationDestination(item: $editing) { id in
            ThemeEditorView(themeID: id)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        start(from: .midnight)
                    } label: {
                        Label("New Theme", systemImage: "plus")
                    }
                    Button {
                        isImporting = true
                    } label: {
                        Label("Import a .itermcolors File…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityIdentifier("theme-add")
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [ITermColorsFile.contentType, .propertyList, .xml, .data],
            allowsMultipleSelection: false
        ) { result in
            importFile(result)
        }
        .confirmationDialog(
            "Delete this theme?",
            isPresented: .init(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { theme in
            Button("Delete", role: .destructive) {
                library.remove(id: theme.id)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { theme in
            // What it costs, before it is spent: which connections lose their colour.
            Text(library.usage(of: theme.id).consequence
                ?? String(localized: "Nothing is using this theme."))
        }
    }

    private func row(_ theme: TerminalTheme) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(theme.name)
            TerminalThemePreview(theme: theme, isCompact: true)
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    private func start(from theme: TerminalTheme) {
        let copy = theme.duplicated(named: uniqueName(basedOn: theme.name))
        library.save(copy)
        editing = copy.id
    }

    /// "Midnight Copy", then "Midnight Copy 2" — a list of five identical names is a list
    /// nobody can use.
    private func uniqueName(basedOn name: String) -> String {
        let base = String(localized: "\(name) Copy")
        let taken = Set(container.settings.allThemes.map(\.name))
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private func importFile(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        // A file chosen from another app arrives security-scoped; without this the read
        // fails with a permissions error that looks like a corrupt file.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let theme = try ITermColorsFile.theme(from: data, named: url.deletingPathExtension().lastPathComponent)
            library.save(theme)
            problem = nil
            editing = theme.id
        } catch let error as STError {
            problem = [error.message, error.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        } catch {
            problem = String(localized: "That file could not be read.")
        }
    }
}
