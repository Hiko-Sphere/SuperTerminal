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
    /// nil is "Automatic": use what the server reports.
    @State private var platformOverride: HostPlatform?
    @State private var vncEnabled = false
    @State private var vncPort = "5900"
    @State private var vncViaSSH = true
    @State private var vncTargetHost = ""
    @State private var vncPassword = ""
    @State private var hasStoredVNCPassword = false

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
            _platformOverride = State(initialValue: host.platformOverride)
            if let vnc = host.vnc {
                _vncEnabled = State(initialValue: true)
                _vncPort = State(initialValue: String(vnc.port))
                _vncViaSSH = State(initialValue: vnc.viaSSH)
                _vncTargetHost = State(initialValue: vnc.targetHost ?? "")
            }
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

                Section {
                    Toggle("Show the server's screen (VNC)", isOn: $vncEnabled.animation())
                        .accessibilityIdentifier("vnc-enabled")
                    if vncEnabled {
                        TextField("VNC port", text: $vncPort)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("vnc-port")
                        Toggle("Through the SSH connection", isOn: $vncViaSSH)
                            .accessibilityIdentifier("vnc-via-ssh")
                        if vncViaSSH {
                            TextField("Screen address as the server sees it (optional)", text: $vncTargetHost)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("vnc-target")
                        }
                        SecureField(hasStoredVNCPassword ? "VNC password (stored — enter to replace)" : "VNC password (optional, saved to Keychain)", text: $vncPassword)
                            .textContentType(.oneTimeCode)
                            .accessibilityIdentifier("vnc-password")
                    }
                } header: {
                    Text("Screen sharing")
                } footer: {
                    if !vncEnabled {
                        Text("Show and control the server's desktop with touch, keyboard and pointer.")
                    } else if vncViaSSH {
                        Text("The screen travels inside the SSH connection, so nothing extra is exposed and the VNC server can stay bound to localhost. Leave the address empty for the server itself.")
                    } else {
                        Text("A direct connection to the VNC port. VNC itself is unencrypted and its password check is weak: use this only on a network you trust.")
                    }
                }

                Section("Advanced") {
                    TextField("Folder", text: $folder)
                    TextField("TERM", text: $terminalType)
                    // Detected on connection; set here when the server's answer is wrong
                    // or when there is a reason to treat it differently (D-019).
                    Picker("Server platform", selection: $platformOverride) {
                        Text("Automatic").tag(HostPlatform?.none)
                        ForEach(HostPlatform.allCases, id: \.self) { platform in
                            Text(platform.title).tag(HostPlatform?.some(platform))
                        }
                    }
                    .accessibilityIdentifier("server-platform")
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
                if let existing {
                    hasStoredServiceToken = container.vault.hasServiceToken(hostID: existing.id)
                    hasStoredVNCPassword = container.vault.hasVNCPassword(hostID: existing.id)
                }
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
            accessAuthentication: usesCloudflare ? accessAuthentication : nil,
            platformOverride: platformOverride,
            detectedPlatform: existing?.detectedPlatform,
            vnc: vncEnabled
                ? Host.VNCSettings(
                    port: Int(vncPort) ?? 0,
                    viaSSH: vncViaSSH,
                    targetHost: vncTargetHost.trimmingCharacters(in: .whitespaces).isEmpty ? nil : vncTargetHost.trimmingCharacters(in: .whitespaces),
                    hasPassword: !vncPassword.isEmpty || hasStoredVNCPassword
                )
                : nil
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
        if vncEnabled, !vncPassword.isEmpty {
            try? container.vault.storeVNCPassword(vncPassword, hostID: host.id)
        } else if !vncEnabled, hasStoredVNCPassword {
            try? container.vault.deleteVNCPassword(hostID: host.id)
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
