import STCore
import SwiftUI

/// Creates or edits a remote screen (D-027).
///
/// A screen is configured on its own, not inside an SSH connection: it has its own
/// address, its own port and its own password, and it names the SSH connection it travels
/// through — which is a choice, not a property of that connection.
struct ScreenEditorView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    private let existing: ScreenConnection?

    @State private var name = ""
    @State private var address = "127.0.0.1"
    @State private var port = ""
    @State private var throughSSH = true
    @State private var sshHostID: UUID?
    @State private var password = ""
    @State private var hasStoredPassword = false

    init(screen: ScreenConnection?) {
        existing = screen
        if let screen {
            _name = State(initialValue: screen.name)
            _address = State(initialValue: screen.address)
            _port = State(initialValue: screen.port == ScreenConnection.defaultPort ? "" : String(screen.port))
            _throughSSH = State(initialValue: !screen.route.isDirect)
            _sshHostID = State(initialValue: screen.route.sshHostID)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("screen-name")
                    TextField("Address", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("screen-address")
                    TextField("Port (blank for 5900)", text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("screen-port")
                } header: {
                    Text("Screen")
                } footer: {
                    if throughSSH {
                        Text("The address as the SSH server sees it. For that server's own desktop this is 127.0.0.1; for another machine on its network, that machine's address. A pasted address carrying its port is taken apart.")
                    } else {
                        Text("The address this device dials. A pasted address carrying its port is taken apart.")
                    }
                }

                Section {
                    Toggle("Through an SSH connection", isOn: $throughSSH.animation())
                        .accessibilityIdentifier("screen-via-ssh")
                    if throughSSH {
                        Picker("SSH connection", selection: $sshHostID) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(container.hostStore.hosts) { host in
                                Text(host.name).tag(UUID?.some(host.id))
                            }
                        }
                        .accessibilityIdentifier("screen-ssh-host")
                    }
                } header: {
                    Text("How it connects")
                } footer: {
                    if throughSSH {
                        Text("The screen travels inside that connection, so the VNC server can stay bound to the server's own localhost and nothing extra is exposed. Its encryption is SSH's.")
                    } else {
                        Text("A direct connection to the VNC port. VNC itself is unencrypted and its password check is weak: use this only on a network you trust.")
                    }
                }

                Section {
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
                    Text("Kept in this device's Keychain, never synced and never in the screen's record. Leave it empty to be asked when the screen opens.")
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
                if let existing { hasStoredPassword = container.vault.hasVNCPassword(screenID: existing.id) }
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

    private var draft: ScreenConnection {
        // A pasted address carrying its port is taken apart, as the SSH editor does (D-024).
        let parsed = HostAddress.parse(address)
        let typedPort = port.trimmingCharacters(in: .whitespaces)
        let resolvedPort = typedPort.isEmpty
            ? (parsed?.port ?? ScreenConnection.defaultPort)
            : (Int(typedPort) ?? 0)
        return ScreenConnection(
            id: existing?.id ?? UUID(),
            name: name,
            address: parsed?.host ?? address.trimmingCharacters(in: .whitespaces),
            port: resolvedPort,
            route: throughSSH ? .throughSSH(hostID: sshHostID ?? UUID()) : .direct,
            hasPassword: !password.isEmpty || hasStoredPassword,
            folder: existing?.folder,
            tags: existing?.tags ?? [],
            lastConnected: existing?.lastConnected
        )
    }

    private var problems: [String] {
        var problems = draft.validationProblems
        if throughSSH, sshHostID == nil {
            problems.append(
                container.hostStore.hosts.isEmpty
                    ? String(localized: "Add an SSH connection first, or connect to the screen directly.")
                    : String(localized: "Choose the SSH connection this screen goes through.")
            )
        }
        return problems
    }

    private func save() {
        let screen = draft
        if !password.isEmpty {
            try? container.vault.storeVNCPassword(password, screenID: screen.id)
        }
        if existing == nil {
            container.screenStore.add(screen)
        } else {
            container.screenStore.update(screen)
        }
        dismiss()
    }
}
