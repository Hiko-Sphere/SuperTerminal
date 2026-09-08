import STSSH
import SwiftUI

/// The authorities this device trusts to vouch for servers (D-046).
///
/// Trusting an authority replaces comparing fingerprints, which is the check people skip —
/// so this is a security improvement rather than a convenience. It is also the most
/// dangerous list in the app: an authority trusted for `*` can vouch for any server
/// anywhere. The patterns are therefore asked for explicitly and shown on every row.
struct CertificateAuthoritiesView: View {
    @Environment(AppContainer.self) private var container
    @State private var editing: SSHCertificateAuthority?
    @State private var isAdding = false

    var body: some View {
        List {
            if container.hostStore.authorities.isEmpty {
                ContentUnavailableView {
                    Label("No trusted authorities", systemImage: "checkmark.seal")
                } description: {
                    Text("A server whose host key carries a certificate from an authority you trust is accepted without you comparing a fingerprint.")
                }
            }
            ForEach(container.hostStore.authorities) { authority in
                Button {
                    editing = authority
                } label: {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        Text(authority.name)
                            .font(DesignTokens.Typography.body)
                        Text(authority.hostPatterns.joined(separator: ", "))
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(
                                authority.hostPatterns.contains("*")
                                    ? DesignTokens.Color.warning
                                    : DesignTokens.Color.labelSecondary
                            )
                        Text(authority.fingerprintSHA256)
                            .font(DesignTokens.Typography.monoCaption)
                            .foregroundStyle(DesignTokens.Color.labelTertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("authority-row")
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        container.hostStore.removeAuthority(id: authority.id)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Trusted Authorities"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Add"), systemImage: "plus") { isAdding = true }
                    .accessibilityIdentifier("add-authority")
            }
        }
        .navigationDestination(isPresented: $isAdding) {
            CertificateAuthorityEditorView(existing: nil)
        }
        .navigationDestination(item: $editing) { authority in
            CertificateAuthorityEditorView(existing: authority)
        }
    }
}

/// Adding or changing one authority.
struct CertificateAuthorityEditorView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let existing: SSHCertificateAuthority?

    @State private var name = ""
    @State private var publicKey = ""
    @State private var patterns = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "Name"), text: $name)
                    .accessibilityIdentifier("authority-name")
            }
            Section {
                TextEditor(text: $publicKey)
                    .font(DesignTokens.Typography.monoCaption)
                    .frame(minHeight: 90)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .accessibilityIdentifier("authority-key")
            } header: {
                Text("Authority public key")
            } footer: {
                Text("The authority's own public key — the `.pub` file, not a certificate. Check its fingerprint against what the authority's owner published before trusting it.")
            }
            Section {
                TextField(String(localized: "Host patterns"), text: $patterns)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("authority-patterns")
            } footer: {
                Text("Separated by commas, in OpenSSH's style: `*.example.com` matches any host under it, `?` matches one character. An authority is trusted only for the hosts it matches — `*` trusts it for every server in the world.")
            }
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .foregroundStyle(DesignTokens.Color.warning)
                        .font(DesignTokens.Typography.callout)
                }
            }
        }
        .navigationTitle(existing == nil
            ? String(localized: "New Authority")
            : String(localized: "Edit Authority"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "Done")) { focused = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save")) { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || publicKey.isEmpty || parsedPatterns.isEmpty)
                    .accessibilityIdentifier("save-authority")
            }
        }
        .task {
            guard let existing else { return }
            name = existing.name
            publicKey = existing.openSSHPublicKey
            patterns = existing.hostPatterns.joined(separator: ", ")
        }
    }

    private var parsedPatterns: [String] {
        patterns.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func save() {
        let authority = SSHCertificateAuthority(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            openSSHPublicKey: publicKey,
            hostPatterns: parsedPatterns
        )
        // Parsed before it is saved: an authority whose key cannot be read would silently
        // vouch for nothing, and the failure would surface as a host-key prompt weeks later.
        do {
            _ = try authority.publicKey()
        } catch {
            problem = String(localized: "That is not a public key this app can read.")
            return
        }
        if existing == nil {
            container.hostStore.add(authority)
        } else {
            container.hostStore.update(authority)
        }
        dismiss()
    }
}
