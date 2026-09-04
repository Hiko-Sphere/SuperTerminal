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
                    } else {
                        TextField("Port", text: $port)
                            .keyboardType(.numberPad)
                    }
                } header: {
                    Text("Transport")
                } footer: {
                    Text(usesCloudflare
                        ? "SuperTerminal signs in to Cloudflare Access in a system browser, then opens the tunnel itself. No cloudflared install is needed on this device."
                        : "A direct SSH connection to the host and port above.")
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
            lastConnected: existing?.lastConnected
        )
    }

    private var problems: [String] { draft.validationProblems }

    private func save() {
        let host = draft
        if usesPassword, !savedPassword.isEmpty {
            try? container.vault.storePassword(savedPassword, hostID: host.id)
        }
        if existing == nil {
            container.hostStore.add(host)
        } else {
            container.hostStore.update(host)
        }
        dismiss()
    }
}
