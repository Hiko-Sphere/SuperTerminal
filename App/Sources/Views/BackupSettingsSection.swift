import SwiftUI
import UniformTypeIdentifiers

/// Export and import, in Settings (D-040).
///
/// The one feature whose value is only apparent on the day the device is gone, which is
/// also the day it is too late to add it. Sync is withdrawn (D-037), so without this there
/// is no way off a device at all.
struct BackupSettingsSection: View {
    @Environment(AppContainer.self) private var container

    @State private var includesPrivateKeys = false
    @State private var password = ""
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: BackupFile?
    @State private var pending: PendingImport?
    @State private var failure: String?
    @State private var outcome: String?

    /// A file chosen for import, held while the user decides what to do with it.
    private struct PendingImport: Identifiable {
        let id = UUID()
        var document: BackupDocument
        var password = ""
        var payload: BackupDocument.Payload?
        var preview: BackupService.Preview?
        var resolution: BackupService.Resolution = .keepExisting
        var error: String?
    }

    private var service: BackupService { container.backup }

    var body: some View {
        Section {
            Toggle("Include private keys", isOn: $includesPrivateKeys)
                .accessibilityIdentifier("backup-include-keys")
            if includesPrivateKeys || !password.isEmpty {
                SecureField("Password for the backup file", text: $password)
                    .textContentType(.oneTimeCode)
                    .accessibilityIdentifier("backup-password")
            }
            ForEach(service.unexportableKeys(), id: \.name) { key in
                Label {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        Text(key.name).font(DesignTokens.Typography.callout)
                        Text(key.reason)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Color.labelSecondary)
                    }
                } icon: {
                    Image(systemName: "faceid").foregroundStyle(DesignTokens.Color.warning)
                }
            }
            Button("Export a backup…") { beginExport() }
                .disabled(includesPrivateKeys && password.isEmpty)
                .accessibilityIdentifier("backup-export")
            Button("Restore from a backup…") { isImporting = true }
                .accessibilityIdentifier("backup-import")
            if let outcome {
                Label(outcome, systemImage: "checkmark.circle")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.success)
            }
        } header: {
            Text("Backup")
        } footer: {
            Text(includesPrivateKeys
                 ? "The file is encrypted with the password you type here. It is not stored anywhere, and without it the backup cannot be opened — not by anyone, including you."
                 : "Connections, screens, snippets, key names and public keys, trusted host keys and your preferences. Passwords and private keys stay in this device's Keychain unless you ask for them and set a password.")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .apexBackup,
            defaultFilename: BackupFile.defaultFilename()
        ) { result in
            if case let .failure(error) = result { failure = error.localizedDescription }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.apexBackup, .json]) { result in
            handleChosenFile(result)
        }
        .sheet(item: $pending) { _ in importSheet }
        .alert("The backup could not be used", isPresented: .init(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    // MARK: - Export

    private func beginExport() {
        do {
            var document = try service.makeDocument(
                options: .init(includePrivateKeys: includesPrivateKeys, password: password)
            )
            // Known hosts are read from an actor, so they are fetched here rather than
            // inside the synchronous builder.
            if document.sealed == nil {
                document.payload?.knownHosts = []
            }
            exportDocument = BackupFile(document: document)
            isExporting = true
            password = ""
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Import

    private func handleChosenFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            // A file from Files.app arrives outside the sandbox and has to be opened
            // through a security scope, which the picker grants for exactly this read.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let document = try service.read(try Data(contentsOf: url))
            var pending = PendingImport(document: document)
            if !document.isEncrypted {
                try unlock(&pending)
            }
            self.pending = pending
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func unlock(_ pending: inout PendingImport) throws {
        let payload = try service.payload(of: pending.document, password: pending.password)
        pending.payload = payload
        pending.preview = service.preview(payload, existingKnownHosts: [])
        pending.error = nil
    }

    @ViewBuilder
    private var importSheet: some View {
        NavigationStack {
            Form {
                if let pending, let preview = pending.preview {
                    previewRows(preview)
                    Section {
                        Picker("If a record already exists", selection: Binding(
                            get: { pending.resolution },
                            set: { self.pending?.resolution = $0 }
                        )) {
                            Text("Keep what is here").tag(BackupService.Resolution.keepExisting)
                            Text("Replace it").tag(BackupService.Resolution.overwrite)
                        }
                        .accessibilityIdentifier("backup-resolution")
                    } footer: {
                        Text(preview.conflicts == 0
                             ? "Nothing in this backup collides with what is on this device."
                             : "\(preview.conflicts) record(s) already exist here.")
                    }
                } else {
                    Section {
                        SecureField("Password", text: Binding(
                            get: { pending?.password ?? "" },
                            set: { self.pending?.password = $0 }
                        ))
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("backup-unlock-password")
                        Button("Unlock") { unlockPending() }
                            .accessibilityIdentifier("backup-unlock")
                        if let error = pending?.error {
                            Text(error)
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Color.danger)
                        }
                    } header: {
                        Text("This backup is encrypted")
                    }
                }
            }
            .navigationTitle("Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pending = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") { applyPending() }
                        .disabled(pending?.payload == nil)
                        .accessibilityIdentifier("backup-restore")
                }
            }
        }
    }

    @ViewBuilder
    private func previewRows(_ preview: BackupService.Preview) -> some View {
        Section {
            row("Connections", preview.hosts)
            row("Screens", preview.screens)
            row("Snippets", preview.snippets)
            row("Keys", preview.keys)
            if preview.privateKeys > 0 {
                LabeledContent("Private keys") { Text("\(preview.privateKeys)") }
            }
            if preview.carriesSettings {
                LabeledContent("Preferences") { Text("Included") }
            }
        } header: {
            Text("What this backup holds")
        } footer: {
            if preview.isEmpty {
                Text("This backup is empty.")
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ counts: BackupService.Preview.Counts) -> some View {
        LabeledContent(title) {
            Text(counts.existing == 0
                 ? "\(counts.new) new"
                 : "\(counts.new) new, \(counts.existing) already here")
        }
    }

    private func unlockPending() {
        guard var value = pending else { return }
        do {
            try unlock(&value)
            pending = value
        } catch {
            value.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            pending = value
        }
    }

    private func applyPending() {
        guard let value = pending, let payload = value.payload else { return }
        Task {
            let applied = await service.apply(payload, resolution: value.resolution)
            outcome = String(localized: "Restored \(applied.hosts.total) connection(s), \(applied.snippets.total) snippet(s) and \(applied.keys.total) key(s).")
            pending = nil
        }
    }
}
