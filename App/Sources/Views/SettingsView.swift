import STSSH
import SwiftUI

struct SettingsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var showsDiagnostics = false
    @State private var confirmingDeletion = false

    var body: some View {
        @Bindable var settings = container.settings

        NavigationStack {
            Form {
                Section("Appearance") {
                    Toggle("Match system light and dark", isOn: $settings.followSystemAppearance)
                    Picker("Dark theme", selection: $settings.themeID) {
                        ForEach(settings.allThemes) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    if settings.followSystemAppearance {
                        Picker("Light theme", selection: $settings.lightThemeID) {
                            ForEach(settings.allThemes) { theme in
                                Text(theme.name).tag(theme.id)
                            }
                        }
                    }
                    Stepper(
                        "Font size \(Int(settings.fontSize)) pt",
                        value: $settings.fontSize,
                        in: AppSettings.fontSizeRange,
                        step: 1
                    )
                    Toggle("Blink the cursor", isOn: $settings.cursorBlink)
                }

                Section {
                    Toggle("Confirm multi-line pastes", isOn: $settings.confirmMultilinePaste)
                    Toggle("Hide content in the App Switcher", isOn: $settings.hideContentInAppSwitcher)
                    Toggle("Record command history", isOn: $settings.commandHistoryEnabled)
                        .onChange(of: settings.commandHistoryEnabled) { _, isEnabled in
                            // The footer promises that turning it off deletes what was
                            // recorded. Making that true here means the promise holds
                            // however the toggle is reached.
                            if !isEnabled { container.snippetStore.clearHistory() }
                        }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Command history is stored only on this device and is off by default. Turning it off deletes what has been recorded.")
                }

                Section {
                    Stepper(
                        "Scrollback \(settings.scrollbackLimit) lines",
                        value: $settings.scrollbackLimit,
                        in: 1000 ... 100_000,
                        step: 1000
                    )
                    Toggle("Keep the screen awake while connected", isOn: $settings.keepAwakeWhileConnected)
                    Toggle("Bell feedback", isOn: $settings.bellEnabled)
                } header: {
                    Text("Terminal")
                }

                Section {
                    Toggle("Reconnect automatically", isOn: $settings.automaticReconnect)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("When a connection drops, SuperTerminal retries on its own and as soon as the network comes back. Your scrollback is kept, and the new shell is marked in the terminal — it starts fresh, in the home directory, with nothing running.")
                }

                Section("Commands") {
                    NavigationLink("Snippets") { SnippetLibraryView() }
                }

                Section("Security") {
                    NavigationLink("Keys") { KeyManagementView() }
                    NavigationLink("Known hosts") { KnownHostsView() }
                    Button("Sign out of all Cloudflare Access apps") {
                        try? container.vault.deleteAllAccessTokens()
                    }
                }

                Section {
                    Button("Export diagnostics") { showsDiagnostics = true }
                    if container.settings.commandHistoryEnabled {
                        Button("Clear command history") { container.snippetStore.clearHistory() }
                    }
                    Button("Delete all data", role: .destructive) { confirmingDeletion = true }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Diagnostics contain no commands, output, hostnames or credentials.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showsDiagnostics) {
                DiagnosticsView(report: container.diagnostics.exportReport())
            }
            .confirmationDialog(
                "Delete every connection, key and saved session?",
                isPresented: $confirmingDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) {
                    container.sessionManager.closeAll()
                    container.hostStore.removeAll()
                    container.snippetStore.removeAll()
                    try? container.vault.deleteEverything()
                }
            } message: {
                Text("This removes your connections, private keys and Cloudflare sessions from this device. It cannot be undone.")
            }
        }
    }
}

struct DiagnosticsView: View {
    let report: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report)
                    .font(DesignTokens.Typography.monoCaption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.Spacing.md)
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: report) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        }
    }
}

struct KnownHostsView: View {
    @Environment(AppContainer.self) private var container
    @State private var entries: [KnownHostEntry] = []

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No known hosts",
                    systemImage: "shield",
                    description: Text("Servers you have connected to appear here with their fingerprints.")
                )
            }
            ForEach(entries, id: \.identity.storageKey) { entry in
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(entry.identity.displayName)
                        .font(DesignTokens.Typography.body)
                    Text(entry.key.fingerprintSHA256)
                        .font(DesignTokens.Typography.monoCaption)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .textSelection(.enabled)
                    Text("First seen \(entry.firstSeen.formatted(date: .abbreviated, time: .shortened))")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.labelTertiary)
                }
                .swipeActions {
                    Button("Forget", systemImage: "trash", role: .destructive) {
                        Task {
                            try? await container.knownHosts.remove(entry.identity)
                            await load()
                        }
                    }
                }
            }
        }
        .navigationTitle("Known hosts")
        .task { await load() }
    }

    private func load() async {
        entries = (try? await container.knownHosts.all()) ?? []
    }
}
