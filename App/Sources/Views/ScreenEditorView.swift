import STCore
import STSSH
import SwiftUI

/// Creates or edits a remote screen (D-027, D-029).
///
/// A screen is configured on its own, not inside an SSH connection: it has its own
/// address, port and password, and how it is reached — through a saved SSH connection,
/// through a Cloudflare Tunnel of its own, or straight over the network — is a choice
/// made here.
struct ScreenEditorView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    private let existing: ScreenConnection?

    /// How the screen is reached, as the editor offers it.
    private enum RouteKind: String, CaseIterable, Identifiable {
        case ssh, cloudflare, direct
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ssh: String(localized: "Through SSH")
            case .cloudflare: String(localized: "Cloudflare")
            case .direct: String(localized: "Direct")
            }
        }
    }

    @State private var name = ""
    @State private var address = "127.0.0.1"
    @State private var port = ""
    @State private var routeKind: RouteKind = .ssh
    @State private var sshHostID: UUID?
    @State private var accessAuthentication: Host.AccessAuthentication = .browserLogin
    @State private var serviceTokenID = ""
    @State private var serviceTokenSecret = ""
    @State private var hasStoredServiceToken = false
    @State private var username = ""
    @State private var password = ""
    @State private var hasStoredPassword = false

    init(screen: ScreenConnection?) {
        existing = screen
        if let screen {
            _name = State(initialValue: screen.name)
            _address = State(initialValue: screen.address)
            _username = State(initialValue: screen.username)
            _port = State(initialValue: screen.port == ScreenConnection.defaultPort(for: screen.route) ? "" : String(screen.port))
            _sshHostID = State(initialValue: screen.route.sshHostID)
            switch screen.route {
            case .throughSSH: _routeKind = State(initialValue: .ssh)
            case .direct: _routeKind = State(initialValue: .direct)
            case let .cloudflare(access):
                _routeKind = State(initialValue: .cloudflare)
                _accessAuthentication = State(initialValue: access)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("screen-name")
                    TextField(routeKind == .cloudflare ? "Hostname" : "Address", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("screen-address")
                    TextField(portPlaceholder, text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("screen-port")
                } header: {
                    Text("Screen")
                } footer: {
                    Text(addressFooter)
                }

                Section {
                    Picker("How it connects", selection: $routeKind.animation()) {
                        ForEach(RouteKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("screen-route")

                    switch routeKind {
                    case .ssh:
                        Picker("SSH connection", selection: $sshHostID) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(container.hostStore.hosts) { host in
                                Text(host.name).tag(UUID?.some(host.id))
                            }
                        }
                        .accessibilityIdentifier("screen-ssh-host")
                    case .cloudflare:
                        Picker("Sign in with", selection: $accessAuthentication) {
                            Text("Browser login").tag(Host.AccessAuthentication.browserLogin)
                            Text("Service token").tag(Host.AccessAuthentication.serviceToken)
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("screen-access-auth")
                        if accessAuthentication == .serviceToken {
                            TextField(hasStoredServiceToken ? "Client ID (stored — enter to replace)" : "Client ID", text: $serviceTokenID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                // Also opted out: AutoFill pairs the text field before a
                                // secure field as a username and offers to save the "login".
                                .textContentType(.oneTimeCode)
                                .accessibilityIdentifier("screen-token-id")
                            SecureField(hasStoredServiceToken ? "Client secret (stored — enter to replace)" : "Client secret", text: $serviceTokenSecret)
                                .textContentType(.oneTimeCode)
                                .accessibilityIdentifier("screen-token-secret")
                        }
                    case .direct:
                        EmptyView()
                    }
                } header: {
                    Text("How it connects")
                } footer: {
                    Text(routeFooter)
                }

                Section {
                    TextField("User name (optional)", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("screen-username")
                    SecureField(hasStoredPassword ? "VNC password (stored — enter to replace)" : "VNC password (optional)", text: $password)
                        // Opts out of iOS Password AutoFill's "Save Password?" sheet, which
                        // would store this secret in iCloud Keychain passwords.
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("screen-password")
                    if hasStoredPassword {
                        Button("Remove stored password", role: .destructive) {
                            if let existing { try? container.vault.deleteVNCPassword(screenID: existing.id) }
                            hasStoredPassword = false
                            password = ""
                        }
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("A user name is only needed for a screen that signs in to an account — a Mac sharing its screen, or a server using VeNCrypt. Leave it empty otherwise. The password is kept in this device's Keychain, never synced and never in the screen's record; leave it empty to be asked when the screen opens.")
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
                    hasStoredPassword = container.vault.hasVNCPassword(screenID: existing.id)
                    hasStoredServiceToken = container.vault.hasServiceToken(screenID: existing.id)
                }
            }
            .navigationTitle(existing == nil ? "New Screen" : "Edit Screen")
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

    private var portPlaceholder: String {
        routeKind == .cloudflare
            ? String(localized: "Port (blank for 443)")
            : String(localized: "Port (blank for 5900)")
    }

    private var addressFooter: String {
        switch routeKind {
        case .ssh:
            String(localized: "The address as the SSH server sees it. For that server's own desktop this is 127.0.0.1; for another machine on its network, that machine's address. A pasted address carrying its port is taken apart.")
        case .cloudflare:
            String(localized: "The hostname the tunnel publishes, and the port the Cloudflare edge is reached on. Where the screen is behind the tunnel is the tunnel's own business.")
        case .direct:
            String(localized: "The address this device dials. A pasted address carrying its port is taken apart.")
        }
    }

    private var routeFooter: String {
        switch routeKind {
        case .ssh:
            String(localized: "The screen travels inside that connection, so the VNC server can stay bound to the server's own localhost and nothing extra is exposed. Its encryption is SSH's.")
        case .cloudflare:
            String(localized: "For a screen published as its own Cloudflare Tunnel hostname — the tunnel's ingress pointing at the VNC server. The picture travels inside the tunnel's TLS, and no cloudflared install is needed on this device.")
        case .direct:
            String(localized: "A direct connection to the VNC port. VNC itself is unencrypted and its password check is weak: use this only on a network you trust.")
        }
    }

    private var route: ScreenConnection.Route {
        switch routeKind {
        case .ssh: .throughSSH(hostID: sshHostID ?? UUID())
        case .cloudflare: .cloudflare(access: accessAuthentication)
        case .direct: .direct
        }
    }

    private var draft: ScreenConnection {
        // A pasted address carrying its port is taken apart, as the SSH editor does (D-024).
        let parsed = HostAddress.parse(address)
        let typedPort = port.trimmingCharacters(in: .whitespaces)
        let route = route
        let resolvedPort = typedPort.isEmpty
            ? (parsed?.port ?? ScreenConnection.defaultPort(for: route))
            : (Int(typedPort) ?? 0)
        return ScreenConnection(
            id: existing?.id ?? UUID(),
            name: name,
            address: parsed?.host ?? address.trimmingCharacters(in: .whitespaces),
            port: resolvedPort,
            route: route,
            username: username.trimmingCharacters(in: .whitespaces),
            hasPassword: !password.isEmpty || hasStoredPassword,
            folder: existing?.folder,
            tags: existing?.tags ?? [],
            lastConnected: existing?.lastConnected
        )
    }

    private var problems: [String] {
        var problems = draft.validationProblems
        if routeKind == .ssh, sshHostID == nil {
            problems.append(
                container.hostStore.hosts.isEmpty
                    ? String(localized: "Add an SSH connection first, or connect to the screen another way.")
                    : String(localized: "Choose the SSH connection this screen goes through.")
            )
        }
        // The secret never enters the model, so the model cannot see this one.
        if routeKind == .cloudflare, accessAuthentication == .serviceToken {
            let typedBoth = !serviceTokenID.isEmpty && !serviceTokenSecret.isEmpty
            let typedNeither = serviceTokenID.isEmpty && serviceTokenSecret.isEmpty
            if !(typedBoth || (hasStoredServiceToken && typedNeither)) {
                problems.append(String(localized: "Enter the service token's client ID and secret."))
            }
        }
        return problems
    }

    private func save() {
        let screen = draft
        if !password.isEmpty {
            try? container.vault.storeVNCPassword(password, screenID: screen.id)
        }
        if screen.usesServiceToken {
            if !serviceTokenID.isEmpty, !serviceTokenSecret.isEmpty {
                try? container.vault.storeServiceToken(clientID: serviceTokenID, secret: serviceTokenSecret, screenID: screen.id)
            }
        } else if hasStoredServiceToken {
            // No longer used by this screen; a credential nothing uses is only a risk.
            try? container.vault.deleteServiceToken(screenID: screen.id)
        }
        if existing == nil {
            container.screenStore.add(screen)
        } else {
            container.screenStore.update(screen)
        }
        dismiss()
    }
}
