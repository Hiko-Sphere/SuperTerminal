import STCore
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
    /// Blank means the transport's default: 22 direct, 443 through Cloudflare.
    @State private var port = ""
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
    @State private var forwardsAgent = false
    @State private var usesTmux = false
    @State private var tmuxSessionName = ""
    @State private var savedPassword = ""
    @State private var folder = ""
    @State private var terminalType = "xterm-256color"
    /// nil is "Automatic": use what the server reports.
    @State private var platformOverride: HostPlatform?
    @State private var showsInFiles = false
    @State private var jumpHosts: [UUID] = []

    /// - Parameter startsWithCloudflare: how a *new* connection opens. The add menu asks
    ///   which kind is being made (D-053), because "SSH server" and "hostname behind
    ///   Cloudflare Access" are different things to set up and burying the difference in a
    ///   toggle two thirds of the way down a form made the second one look like an
    ///   afterthought. Ignored when editing, where the record already says.
    /// - Parameter draft: fields a link asked for (D-061). Filled in, never saved: a
    ///   connection appears in the list when somebody chooses to put it there, and a link
    ///   is not that choice.
    /// Told what was saved, for a caller that wants to do something with it — putting a
    /// newly added server straight into the pane that asked for it (D-074).
    private let onSaved: (Host) -> Void

    init(
        host: Host?,
        startsWithCloudflare: Bool = false,
        draft: IncomingURL.SSHAddress? = nil,
        onSaved: @escaping (Host) -> Void = { _ in }
    ) {
        existing = host
        self.onSaved = onSaved
        if host == nil, startsWithCloudflare {
            _usesCloudflare = State(initialValue: true)
        }
        if host == nil, let draft {
            _hostname = State(initialValue: draft.host)
            _name = State(initialValue: draft.host)
            if let port = draft.port { _port = State(initialValue: "\(port)") }
            if let username = draft.username { _username = State(initialValue: username) }
        }
        if let host {
            _name = State(initialValue: host.name)
            _hostname = State(initialValue: host.hostname)
            _port = State(initialValue: host.port == Host.defaultPort(for: host.transport) ? "" : String(host.port))
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
            _forwardsAgent = State(initialValue: host.isForwardingAgent)
            _usesTmux = State(initialValue: host.isUsingTmux)
            _tmuxSessionName = State(initialValue: host.tmuxSessionName ?? "")
            _folder = State(initialValue: host.folder ?? "")
            _terminalType = State(initialValue: host.terminalType)
            _platformOverride = State(initialValue: host.platformOverride)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Hostname", text: $hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("hostname")
                    TextField(usesCloudflare ? "Port (blank for 443)" : "Port (blank for 22)", text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("port")
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("username")
                } header: {
                    Text("Connection")
                } footer: {
                    Text("A pasted address is taken apart: ssh.example.com:443, ssh://deploy@host:2222 and [2001:db8::1]:22 all work. A blank user name is asked for each time the connection opens.")
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
                    }
                } header: {
                    Text("Transport")
                } footer: {
                    if !usesCloudflare {
                        Text("A direct SSH connection to the host and port above.")
                    } else if accessAuthentication == .serviceToken {
                        Text("A service token signs in without a browser. Create one in Cloudflare Zero Trust → Access → Service Auth and allow it in the application's policy. It is kept in this device's Keychain, never synced, and deleted with the connection.")
                    } else {
                        Text("Apex Terminal signs in to Cloudflare Access in a system browser, then opens the tunnel itself. No cloudflared install is needed on this device.")
                    }
                }

                Section {
                    Picker("Private key", selection: $selectedKeyID) {
                        Text("None").tag(UUID?.none)
                        ForEach(container.hostStore.keys) { key in
                            // Where the key lives belongs in this list: it decides whether
                            // the connection can run without you, and whether the key works
                            // on this device at all.
                            Text(
                                key.isHeldInSecureEnclave
                                    ? String(localized: "\(key.name) · \(key.algorithm) · Secure Enclave")
                                    : String(localized: "\(key.name) · \(key.algorithm)")
                            )
                            .tag(UUID?.some(key.id))
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
                    Text("Credentials are stored in the Keychain, never in the connection list. Leave the password empty to be asked each time. With no key and no password chosen, the server is asked what it takes and you are asked for a password only if it takes one.")
                }

                Section {
                    Toggle("Let this server use my key", isOn: $forwardsAgent)
                        .disabled(selectedKeyID == nil)
                        .accessibilityIdentifier("host-agent-forwarding")
                } header: {
                    Text("Agent forwarding")
                } footer: {
                    if selectedKeyID == nil {
                        Text("Choose a private key above first. Agent forwarding offers the key this connection already uses, and nothing else.")
                    } else if forwardsAgent {
                        // The risk, in the place the decision is made, and specific about
                        // who can do what rather than a generic caution.
                        Text("While you are connected, anything running as root on this server can ask your device to sign with this key — including for connections to other servers. It cannot read the key, and signing stops the moment you disconnect. Turn this on for machines you trust; leave it off for shared ones.")
                    } else {
                        Text("Off. Programs on the server cannot use your key. Turn this on only if you need to reach another server, or a Git remote, from a shell on this one.")
                    }
                }

                Section {
                    Toggle("Attach to tmux", isOn: $usesTmux.animation())
                        .accessibilityIdentifier("host-uses-tmux")
                    if usesTmux {
                        TextField("Session name", text: $tmuxSessionName, prompt: Text(verbatim: "apex"))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("host-tmux-session")
                    }
                } header: {
                    Text("tmux")
                } footer: {
                    if usesTmux {
                        Text("Opening this connection attaches to a tmux session on the server, creating it if it is not there. What is running stays running when you disconnect, and tmux decides how the panes are arranged. tmux must be installed on the server.")
                    } else {
                        Text("Off. Opening this connection starts an ordinary shell, and what is running in it ends when the connection does.")
                    }
                }

                // Only for a direct connection: a Cloudflare tunnel *is* the transport,
                // and it has its own bastion setting above.
                if !usesCloudflare {
                    JumpHostsSection(hostID: existing?.id, jumpHosts: $jumpHosts)
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

                // Only for a connection that already exists: whether it can be
                // published depends on a host key that has been checked and a credential
                // that is stored, and neither is true of a connection still being typed.
                if let existing {
                    HostFilesSection(host: existing, showsInFiles: $showsInFiles)
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
                    showsInFiles = existing.isPublishedToFiles
                    jumpHosts = existing.jumpHosts ?? []
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

    /// The connection as the editor would save it.
    ///
    /// The edits are applied to the existing record rather than used to build a new one,
    /// so a field the editor does not show cannot be dropped by forgetting to list it.
    /// `HostEditorFields` and `Host.applying(_:)` carry that rule, and a test holds it.
    private var draft: Host {
        var credentials: [Host.CredentialReference] = []
        if let selectedKeyID { credentials.append(.privateKey(id: selectedKeyID)) }
        if usesPassword { credentials.append(.password) }

        // What was typed or pasted into the hostname field, taken apart (D-024): the host
        // is the host; a port or user name that came with it fills a blank field.
        let transport: Host.TransportKind = usesCloudflare
            ? .cloudflare(jumpDestination: jumpDestination.isEmpty ? nil : jumpDestination)
            : .directTCP
        let address = HostAddress.parse(hostname)
        let typedPort = port.trimmingCharacters(in: .whitespaces)
        let resolvedPort = typedPort.isEmpty
            ? (address?.port ?? Host.defaultPort(for: transport))
            : (Int(typedPort) ?? 0)
        let typedUser = username.trimmingCharacters(in: .whitespaces)

        let fields = HostEditorFields(
            name: name,
            hostname: address?.host ?? hostname.trimmingCharacters(in: .whitespaces),
            port: resolvedPort,
            username: typedUser.isEmpty ? (address?.user ?? "") : typedUser,
            transport: transport,
            credentials: credentials,
            folder: folder.isEmpty ? nil : folder,
            terminalType: terminalType,
            accessAuthentication: usesCloudflare ? accessAuthentication : nil,
            platformOverride: platformOverride,
            showsInFiles: showsInFiles,
            jumpHosts: jumpHosts,
            forwardsAgent: forwardsAgent,
            usesTmux: usesTmux,
            tmuxSessionName: tmuxSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return (existing ?? Host(name: "", hostname: "", username: "")).applying(fields)
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
        onSaved(host)
        dismiss()
    }
}
