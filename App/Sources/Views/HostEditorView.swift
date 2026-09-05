import STSSH
import SwiftUI

/// Creates or edits a connection.
///
/// The Cloudflare option is presented as a transport choice rather than an advanced
/// setting, because for this app it is the headline capability — and because the fields
/// it needs are genuinely different from a direct connection's.
struct HostEditorView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    private let existing: Host?

    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var usesCloudflare = false
    @State private var accessAuthentication: Host.AccessAuthentication = .browserLogin
    @State private var serviceTokenID = ""
    @State private var serviceTokenSecret = ""
    /// Whether a token is already in the Keychain for this connection, so the fields can
    /// say "stored" instead of demanding it again.
    @State private var hasStoredServiceToken = false
    @State private var jumpDestination = ""
    @State private var selectedKeyID: UUID?
    @State private var usesPassword = false
    @State private var savedPassword = ""
    @State private var folder = ""
    @State private var terminalType = "xterm-256color"

    init(host: Host?) {
        existing = host
        if let host {
            _name = State(initialValue: host.name)
            _hostname = State(initialValue: host.hostname)
            _port = State(initialValue: String(host.port))
            _username = State(initialValue: host.username)
            _usesCloudflare = State(initialValue: host.transport.isCloudflare)
            if case let .cloudflare(destination) = host.transport {
                _jumpDestination = State(initialValue: destination ?? "")
            }
            _accessAuthentication = State(initialValue: host.accessAuthentication ?? .browserLogin)
            _selectedKeyID = State(initialValue: host.credentials.compactMap {
                if case let .privateKey(id) = $0 { return id }
                return nil
            }.first)
            _usesPassword = State(initialValue: host.credentials.contains(.password))
            _folder = State(initialValue: host.folder ?? "")
            _terminalType = State(initialValue: host.terminalType)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Hostname", text: $hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Toggle("Through Cloudflare Tunnel", isOn: $usesCloudflare.animation())
                    if usesCloudflare {
                        TextField("Bastion destination (optional)", text: $jumpDestination)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Picker("Sign in with", selection: $accessAuthentication) {
                            Text("Browser login").tag(Host.AccessAuthentication.browserLogin)
                            Text("Service token").tag(Host.AccessAuthentication.serviceToken)
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("access-auth-picker")
                        if accessAuthentication == .serviceToken {
                            TextField(hasStoredServiceToken ? "Client ID (stored — enter to replace)" : "Client ID", text: $serviceTokenID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                // Also opted out: AutoFill pairs the text field before a secure field as a
                                // username and then offers to save the "login".
                                .textContentType(.oneTimeCode)
                                .accessibilityIdentifier("service-token-id")
                            SecureField(hasStoredServiceToken ? "Client secret (stored — enter to replace)" : "Client secret", text: $serviceTokenSecret)
                                // Opts out of iOS Password AutoFill's "Save Password?" sheet, which would store
                                // this secret in iCloud Keychain passwords — the one place the policy says it never goes.
                                .textContentType(.oneTimeCode)
                                .accessibilityIdentifier("service-token-secret")
                        }
                    } else {
                        TextField("Port", text: $port)
                            .keyboardType(.numberPad)
                    }
                } header: {
                    Text("Transport")
                } footer: {
                    if !usesCloudflare {
                        Text("A direct SSH connection to the host and port above.")
                    } else if accessAuthentication == .serviceToken {
                        Text("A service token signs in without a browser. Create one in Cloudflare Zero Trust → Access → Service Auth and allow it in the application's policy. It is kept in this device's Keychain, never synced, and deleted with the connection.")
                    } else {
                        Text("SuperTerminal signs in to Cloudflare Access in a system browser, then opens the tunnel itself. No cloudflared install is needed on this device.")
                    }
                }

                Section {
                    Picker("Private key", selection: $selectedKeyID) {
                        Text("None").tag(UUID?.none)
                        ForEach(container.hostStore.keys) { key in
                            Text("\(key.name) · \(key.algorithm)").tag(UUID?.some(key.id))
                        }
                    }
                    Toggle("Offer a password", isOn: $usesPassword)
                    if usesPassword {
                        SecureField("Password (optional, saved to Keychain)", text: $savedPassword)
                            // Opts out of iOS Password AutoFill's "Save Password?" sheet, which would store
                            // this secret in iCloud Keychain passwords — the one place the policy says it never goes.
                            .textContentType(.oneTimeCode)
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Credentials are stored in the Keychain, never in the connection list. Leave the password empty to be asked each time.")
                }

                Section("Advanced") {
                    TextField("Folder", text: $folder)
                    TextField("TERM", text: $terminalType)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if !problems.isEmpty {
                    Section("Before you can save") {
                        ForEach(problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.circle")
                                .foregroundStyle(DesignTokens.Color.warning)
                                .font(DesignTokens.Typography.callout)
                        }
                    }
                }
            }
            .task {
                if let existing { hasStoredServiceToken = container.vault.hasServiceToken(hostID: existing.id) }
            }
            .navigationTitle(existing == nil ? "New Connection" : "Edit Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!problems.isEmpty)
                }
            }
        }
    }

    private var draft: Host {
        var credentials: [Host.CredentialReference] = []
        if let selectedKeyID { credentials.append(.privateKey(id: selectedKeyID)) }
        if usesPassword { credentials.append(.password) }

        return Host(
            id: existing?.id ?? UUID(),
            name: name,
            hostname: hostname.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? 22,
            username: username.trimmingCharacters(in: .whitespaces),
            transport: usesCloudflare
                ? .cloudflare(jumpDestination: jumpDestination.isEmpty ? nil : jumpDestination)
                : .directTCP,
            credentials: credentials,
            folder: folder.isEmpty ? nil : folder,
            tags: existing?.tags ?? [],
            terminalType: terminalType,
            environment: existing?.environment ?? [:],
            themeID: existing?.themeID,
            lastConnected: existing?.lastConnected,
            accessAuthentication: usesCloudflare ? accessAuthentication : nil
        )
    }

    private var problems: [String] { draft.validationProblems + editorProblems }

    /// Problems the model cannot see because the secret never enters the model.
    private var editorProblems: [String] {
        guard usesCloudflare, accessAuthentication == .serviceToken else { return [] }
        let typedBoth = !serviceTokenID.isEmpty && !serviceTokenSecret.isEmpty
        let typedNeither = serviceTokenID.isEmpty && serviceTokenSecret.isEmpty
        if typedBoth || (hasStoredServiceToken && typedNeither) { return [] }
        return [String(localized: "Enter the service token's client ID and secret.")]
    }

    private func save() {
        let host = draft
        if usesPassword, !savedPassword.isEmpty {
            try? container.vault.storePassword(savedPassword, hostID: host.id)
        }
        if host.usesServiceToken {
            if !serviceTokenID.isEmpty, !serviceTokenSecret.isEmpty {
                try? container.vault.storeServiceToken(clientID: serviceTokenID, secret: serviceTokenSecret, hostID: host.id)
            }
        } else if hasStoredServiceToken {
            // No longer used by this connection; a credential nothing uses is only a risk.
            try? container.vault.deleteServiceToken(hostID: host.id)
        }
        if existing == nil {
            container.hostStore.add(host)
        } else {
            container.hostStore.update(host)
        }
        dismiss()
    }
}
