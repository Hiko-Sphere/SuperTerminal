import STCore
import STSSH
import SwiftUI
import UniformTypeIdentifiers

/// Manages the private keys the app can authenticate with.
///
/// The private half never appears in this screen. Everything shown — the fingerprint, the
/// algorithm, the public key — is safe to display, copy and share, which is what makes
/// "copy this to your server" a one-tap action rather than a dangerous one.
struct KeyManagementView: View {
    @Environment(AppContainer.self) private var container

    @State private var isGenerating = false
    @State private var isImporting = false
    @State private var importedText = ""
    @State private var errorMessage: String?
    @State private var keyToDelete: StoredKey?

    var body: some View {
        List {
            if container.hostStore.keys.isEmpty {
                ContentUnavailableView {
                    Label("No keys yet", systemImage: "key")
                } description: {
                    Text("Generate a key here and add its public half to your server, or import a key you already have.")
                } actions: {
                    Button("Generate a Key") { isGenerating = true }
                }
            }

            ForEach(container.hostStore.keys) { key in
                KeyRow(key: key)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            keyToDelete = key
                        }
                    }
            }
        }
        .navigationTitle("Keys")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Generate…", systemImage: "sparkles") { isGenerating = true }
                    Button("Import…", systemImage: "square.and.arrow.down") { isImporting = true }
                } label: {
                    Label("Add key", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isGenerating) {
            GenerateKeySheet()
        }
        .sheet(isPresented: $isImporting) {
            ImportKeySheet()
        }
        .alert("Key problem", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete “\(keyToDelete?.name ?? "")”?",
            isPresented: .constant(keyToDelete != nil),
            titleVisibility: .visible
        ) {
            Button("Delete key", role: .destructive) {
                if let key = keyToDelete {
                    // The Keychain item goes first: a record without its key is a
                    // confusing failure later, but a key without its record is invisible
                    // material left behind on the device.
                    try? container.vault.deletePrivateKey(id: key.id)
                    container.hostStore.remove(keyID: key.id)
                }
                keyToDelete = nil
            }
            Button("Cancel", role: .cancel) { keyToDelete = nil }
        } message: {
            Text("The private key is removed from this device and any connection using it will stop working. This cannot be undone.")
        }
    }
}

private struct KeyRow: View {
    @Environment(AppContainer.self) private var container
    let key: StoredKey
    /// Checked once per appearance, attribute-only, so listing never prompts.
    @State private var hasSecret = true

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Text(key.name)
                    .font(DesignTokens.Typography.body)
                Spacer()
                Text(key.algorithm)
                    .font(DesignTokens.Typography.caption)
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.vertical, DesignTokens.Spacing.xxs)
                    .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
            }
            Text(key.fingerprintSHA256)
                .font(DesignTokens.Typography.monoCaption)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
                .textSelection(.enabled)
            HStack(spacing: DesignTokens.Spacing.lg) {
                Button {
                    UIPasteboard.general.string = key.publicKeyOpenSSH
                    container.haptics.play(.textInserted)
                } label: {
                    Label("Copy public key", systemImage: "doc.on.doc")
                }
                ShareLink(item: key.publicKeyOpenSSH) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            .font(DesignTokens.Typography.caption)
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Color.accent)
            if key.requiresBiometrics {
                Label("Unlocks with Face ID or Touch ID", systemImage: "faceid")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
            }
            if !hasSecret {
                Label("Private key is not on this device", systemImage: "icloud.slash")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.warning)
            } else if key.secretInICloud == true {
                Label("In iCloud Keychain", systemImage: "icloud")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
            }
        }
        .task(id: key.id) { hasSecret = container.vault.hasPrivateKey(id: key.id) }
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

/// Generates a new key on the device.
struct GenerateKeySheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var algorithm: SSHKeyAlgorithm = .ed25519
    @State private var requireBiometrics = true
    @State private var storeSecretInICloud = false
    @State private var generated: SSHKeyGenerator.GeneratedKey?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let generated {
                    Section {
                        Text(generated.fingerprintSHA256)
                            .font(DesignTokens.Typography.monoCaption)
                            .textSelection(.enabled)
                        Text(generated.publicKeyOpenSSH)
                            .font(DesignTokens.Typography.monoCaption)
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = generated.publicKeyOpenSSH
                        } label: {
                            Label("Copy public key", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: generated.publicKeyOpenSSH) {
                            Label("Share public key", systemImage: "square.and.arrow.up")
                        }
                    } header: {
                        Text("Key created")
                    } footer: {
                        // The next step is the one people forget, so it is spelled out.
                        Text("Add this line to ~/.ssh/authorized_keys on the server. The private half stays on this device and is never shown or shared.")
                    }
                } else {
                    Section("Key") {
                        TextField("Name", text: $name)
                            .textInputAutocapitalization(.words)
                        Picker("Algorithm", selection: $algorithm) {
                            ForEach(SSHKeyAlgorithm.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        Text(algorithm.detail)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Color.labelSecondary)
                    }

                    Section {
                        Toggle("Require Face ID or Touch ID", isOn: $requireBiometrics)
                    } footer: {
                        Text("The key can only be used after a successful biometric or passcode check, and becomes unusable if the device's biometric enrolment changes.")
                    }

                    ICloudKeyChoice(requireBiometrics: requireBiometrics, storeSecretInICloud: $storeSecretInICloud)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(DesignTokens.Color.danger)
                    }
                }
            }
            .navigationTitle(generated == nil ? "New Key" : "Key Created")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(generated == nil ? "Cancel" : "Done") { dismiss() }
                }
                if generated == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Generate") { generate() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func generate() {
        do {
            let comment = "\(name.replacingOccurrences(of: " ", with: "-"))@superterminal"
            let key = try SSHKeyGenerator.generate(algorithm: algorithm, comment: comment)
            let record = StoredKey(
                name: name,
                algorithm: key.algorithm.sshName,
                publicKeyOpenSSH: key.publicKeyOpenSSH,
                fingerprintSHA256: key.fingerprintSHA256,
                requiresBiometrics: requireBiometrics,
                isPassphraseProtected: false,
                secretInICloud: storeSecretInICloud
            )
            // Stored before the record is added, so a Keychain failure cannot leave a
            // record pointing at a key that does not exist.
            try container.vault.storePrivateKey(
                key.privateKeyPEM,
                id: record.id,
                requireBiometrics: requireBiometrics,
                syncToICloud: storeSecretInICloud
            )
            container.hostStore.add(record)
            generated = key
            errorMessage = nil
        } catch let error as CredentialVaultError {
            errorMessage = error.errorDescription
        } catch let error as STError {
            errorMessage = error.message
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

/// Imports a key the user already has.
struct ImportKeySheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var pem = ""
    @State private var passphrase = ""
    @State private var requiresPassphrase = false
    @State private var requireBiometrics = true
    @State private var storeSecretInICloud = false
    @State private var errorMessage: String?
    @State private var isShowingFileImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Key") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    Button("Choose a file…", systemImage: "folder") {
                        isShowingFileImporter = true
                    }
                }

                Section {
                    TextEditor(text: $pem)
                        .font(DesignTokens.Typography.monoCaption)
                        .frame(minHeight: 160)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Private key")
                } footer: {
                    Text("Paste an OpenSSH private key, beginning with -----BEGIN OPENSSH PRIVATE KEY-----. It is stored in the Keychain and never leaves this device.")
                }

                if requiresPassphrase {
                    Section {
                        SecureField("Passphrase", text: $passphrase)
                    } footer: {
                        Text("This key is encrypted. The passphrase is used once to unlock it and is not stored.")
                    }
                }

                Section {
                    Toggle("Require Face ID or Touch ID", isOn: $requireBiometrics)
                }

                ICloudKeyChoice(requireBiometrics: requireBiometrics, storeSecretInICloud: $storeSecretInICloud)

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(DesignTokens.Color.danger)
                    }
                }
            }
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: pem) { _, _ in inspect() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importKey() }
                        .disabled(pem.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.data, .text],
                allowsMultipleSelection: false
            ) { result in
                guard case let .success(urls) = result, let url = urls.first else { return }
                // A file chosen from another app arrives security-scoped; without this the
                // read fails with a permissions error that looks like a corrupt file.
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    pem = text
                    if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                } else {
                    errorMessage = String(localized: "That file could not be read as text.")
                }
            }
        }
    }

    /// Looks at the key without unlocking it, so the passphrase field only appears when
    /// one is actually needed.
    private func inspect() {
        guard !pem.isEmpty else {
            requiresPassphrase = false
            return
        }
        do {
            requiresPassphrase = try OpenSSHPrivateKeyParser.inspect(pem: pem).isEncrypted
            errorMessage = nil
        } catch let error as SSHKeyParseError {
            requiresPassphrase = false
            errorMessage = error.stError.message
        } catch {
            requiresPassphrase = false
        }
    }

    private func importKey() {
        do {
            // Parsed before it is stored, so an unusable key is refused at import rather
            // than at the first connection attempt.
            let material = try OpenSSHPrivateKeyParser.parse(
                pem: pem,
                passphrase: passphrase.isEmpty ? nil : passphrase
            )
            let record = StoredKey(
                name: name,
                algorithm: material.algorithm,
                publicKeyOpenSSH: material.publicKey.openSSHRepresentation,
                fingerprintSHA256: material.publicKey.fingerprintSHA256,
                requiresBiometrics: requireBiometrics,
                isPassphraseProtected: requiresPassphrase,
                secretInICloud: storeSecretInICloud
            )
            try container.vault.storePrivateKey(pem, id: record.id, requireBiometrics: requireBiometrics, syncToICloud: storeSecretInICloud)
            container.hostStore.add(record)
            dismiss()
        } catch let error as SSHKeyParseError {
            errorMessage = error.stError.message
        } catch let error as CredentialVaultError {
            errorMessage = error.errorDescription
        } catch let error as STError {
            errorMessage = error.message
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

/// Per-key iCloud Keychain choice. Shown as a real control only when it can do
/// something; otherwise it says what would make it available.
private struct ICloudKeyChoice: View {
    @Environment(AppContainer.self) private var container
    let requireBiometrics: Bool
    @Binding var storeSecretInICloud: Bool

    var body: some View {
        Section {
            if container.sync.isEnabled {
                Toggle("Store private key in iCloud Keychain", isOn: $storeSecretInICloud)
                    .disabled(requireBiometrics)
                    .onChange(of: requireBiometrics) { _, biometrics in
                        if biometrics { storeSecretInICloud = false }
                    }
            }
        } footer: {
            if !container.sync.isEnabled {
                Text("Turn on Sync with iCloud in Settings to keep this key in iCloud Keychain. The key's name and public key sync either way.")
            } else if requireBiometrics {
                Text("A key protected by Face ID or Touch ID stays on this device; iCloud Keychain cannot hold it.")
            } else {
                Text("Every device signed in to your iCloud account and trusted for iCloud Keychain receives the private key.")
            }
        }
    }
}
