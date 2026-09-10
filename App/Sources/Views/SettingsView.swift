import STSSH
import SwiftUI

struct SettingsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showsDiagnostics = false
    @State private var confirmingDeletion = false

    /// The language iOS actually resolved for this app, in that language's own words.
    ///
    /// Read from the bundle rather than from `Locale.current`: the two differ whenever the
    /// user has set a per-app language, and the bundle is the one that decided what is on
    /// screen.
    private var currentLanguageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: code).localizedString(forIdentifier: code)?.capitalized(with: Locale(identifier: code))
            ?? code
    }

    /// Read once when the screen appears: enumerating families and measuring each one is
    /// not something to do on every redraw.
    @State private var monospacedFonts: [String] = []

    var body: some View {
        @Bindable var settings = container.settings

        NavigationStack {
            Form {
                Section {
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
                    Picker("Font", selection: $settings.fontFamily) {
                        Text("System").tag(TerminalFont.systemFamily)
                        ForEach(monospacedFonts, id: \.self) { family in
                            // Each name in its own face: the point of choosing a terminal
                            // font is what the glyphs look like, not what it is called.
                            // Resolved the same way the terminal resolves it, so the row
                            // cannot show one face and the screen draw another.
                            Text(family)
                                .font(Font(TerminalFont.faces(family: family, size: 16).regular))
                                .tag(family)
                        }
                    }
                    .accessibilityIdentifier("settings-font")
                    Stepper(
                        "Line height \(settings.lineHeightMultiple, format: .number.precision(.fractionLength(2)))×",
                        value: $settings.lineHeightMultiple,
                        in: AppSettings.lineHeightRange,
                        step: 0.05
                    )
                    .accessibilityIdentifier("settings-line-height")
                    Toggle("Font ligatures", isOn: $settings.fontLigatures)
                        .accessibilityIdentifier("settings-ligatures")
                    FontSampleView(
                        family: settings.fontFamily,
                        size: settings.fontSize,
                        lineHeightMultiple: settings.lineHeightMultiple,
                        ligaturesEnabled: settings.fontLigatures
                    )
                    NavigationLink("Themes") { LazyDestination { ThemeWorkshopView() } }
                        .accessibilityIdentifier("settings-themes")
                    Toggle("Blink the cursor", isOn: $settings.cursorBlink)
                    Toggle("Haptic feedback", isOn: $settings.hapticsEnabled)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Only fonts where every character is the same width are offered: a terminal draws a grid, and a font that does not measure evenly draws a screen that does not line up. Ligatures are off by default because a font that draws != as one glyph is drawing two cells as one.")
                }

                // Its own section rather than appended to Appearance, which already runs long
                // enough that new rows would land below the fold on a phone — and a row below
                // the fold is not in the accessibility tree at all (D-068).
                BackdropSettingsSection()

                AppLockSettingsSection()

                Section {
                    Toggle("Confirm multi-line pastes", isOn: $settings.confirmMultilinePaste)
                    Toggle("Hide content in the App Switcher", isOn: $settings.hideContentInAppSwitcher)
                    Toggle("Find connections in Spotlight", isOn: $settings.spotlightEnabled)
                        .accessibilityIdentifier("settings-spotlight")
                        .onChange(of: settings.spotlightEnabled) { _, enabled in
                            // Turning it off removes what was indexed rather than leaving
                            // it behind: the footer says the names stop being searchable,
                            // and that has to be true the moment the switch moves.
                            container.spotlight.update(hosts: container.hostStore.hosts, enabled: enabled)
                        }
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
                    Text("Command history is stored only on this device and is off by default. Turning it off deletes what has been recorded. Spotlight is off too: turning it on gives the names and addresses of your connections to this device's search index, where they can be found without opening the app. Turning it off removes them again. Passwords, keys and host keys are never indexed.")
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
                    Text("When a connection drops, Apex Terminal retries on its own and as soon as the network comes back. Your scrollback is kept, and the new shell is marked in the terminal — it starts fresh, in the home directory, with nothing running.")
                }

                Section {
                    Button {
                        // iOS owns per-app language. An in-app override would have to
                        // rebuild every view hierarchy to take effect, and would disagree
                        // with what Settings.app reports — so this goes where the real
                        // control lives rather than pretending to be it.
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        HStack {
                            Text("Language")
                                .foregroundStyle(DesignTokens.Color.label)
                            Spacer()
                            Text(currentLanguageName)
                                .foregroundStyle(DesignTokens.Color.labelSecondary)
                            Image(systemName: "arrow.up.forward.app")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Color.labelTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityHint("Opens this app's language setting in Settings")
                } header: {
                    Text("Language")
                } footer: {
                    Text("Apex Terminal is available in English, Simplified Chinese and Traditional Chinese. Terminal output is never translated — it comes from the remote machine exactly as it was sent.")
                }

                Section("Commands") {
                    NavigationLink("Snippets") { SnippetLibraryView() }
                        .accessibilityIdentifier("settings-snippets")
                }

                AssistantSettingsSection()

                Section {
                    NavigationLink("Keys") { KeyManagementView() }
                        .accessibilityIdentifier("settings-keys")
                    NavigationLink("Known hosts") { KnownHostsView() }
                    NavigationLink("Trusted authorities") { CertificateAuthoritiesView() }
                        .accessibilityIdentifier("settings-authorities")
                        .accessibilityIdentifier("settings-known-hosts")
                    Toggle("Let programs copy to my clipboard", isOn: $settings.remoteClipboardWrites)
                        .accessibilityIdentifier("settings-remote-clipboard")
                    Picker("Clear copied text after", selection: $settings.clipboardExpirySeconds) {
                        Text("Never").tag(0)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                    }
                    Button("Sign out of all Cloudflare Access apps") {
                        try? container.vault.deleteAllAccessTokens()
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Text copied from the terminal is removed from the clipboard by iOS after this long. Public keys copied from the key list stay until replaced.\n\nPrograms on a server can ask to copy to this device's clipboard — tmux and vim use it to make yank reach you. It is off until you turn it on, because it is somebody else's machine writing where your copied text lives. Reading your clipboard is never allowed, whatever this says.")
                }

                ICloudSyncSection()

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

                BackupSettingsSection()

                HelpSettingsSection()

                Section("Legal") {
                    ForEach([LegalDocument.terms, .privacy, .notice, .licences]) { document in
                        NavigationLink(document.title) { LegalView(document: document) }
                            .accessibilityIdentifier("settings-legal-\(document.rawValue)")
                    }
                }

                Section {
                    AboutRow()
                }
                .listRowBackground(Color.clear)
            }
            // For UI tests to scroll the *form* — on iPad a form sheet leaves the
            // connection list visible behind it, and neither position in the tree nor
            // a localized label identifies which collection view is which.
            .accessibilityIdentifier("settings-form")
            .task {
                // Measuring every family on the device takes long enough to be worth doing
                // once, and off the main thread: this runs while the screen is animating in
                // (D-063). Font enumeration and string measurement are not main-actor work,
                // which is why the detached task can do it.
                guard monospacedFonts.isEmpty else { return }
                monospacedFonts = await Task.detached(priority: .userInitiated) {
                    TerminalFont.monospacedFamilies()
                }.value
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
                    container.restoration.clear()
                    container.screens.closeAll()
                    container.screenStore.removeAll()
                    try? container.vault.deleteEverything()
                    Task {
                        // Host keys too: left behind with sync on, they would come back.
                        try? await container.knownHosts.removeAll()
                        if container.sync.isEnabled { try? await container.sync.purgeRemote() }
                        container.sync.setEnabled(false)
                    }
                }
            } message: {
                Text(container.sync.isEnabled
                    ? "This removes your connections, private keys, host keys and Cloudflare sessions from this device and from iCloud. It cannot be undone."
                    : "This removes your connections, private keys, host keys and Cloudflare sessions from this device. It cannot be undone.")
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
                            container.sync.recordDeletion(ofKnownHost: entry.identity)
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


/// The app's mark and version, at the foot of Settings.
///
/// A template image, so it takes the label colour and follows light and dark rather than
/// being a black rectangle in one of them. The version is read from the bundle rather than
/// written down, because a version string that has to be edited by hand is a version string
/// that ends up wrong.
private struct AboutRow: View {
    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image("Logo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
            Text("Apex Terminal")
                .font(DesignTokens.Typography.headline)
                .foregroundStyle(DesignTokens.Color.label)
            Text(versionSummary)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.labelTertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Apex Terminal, \(versionSummary)")
    }

    private var versionSummary: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(version) (\(build))"
    }
}
