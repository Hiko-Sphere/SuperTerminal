import STSSH
import SwiftUI

/// Presents the decisions only a person can make.
///
/// The host key sheets in particular are written to be *read*: a fingerprint the user
/// skims past is not a security control, and the changed-key case is deliberately styled
/// so that continuing feels like the unusual choice it is.
struct PromptSheet: View {
    let prompt: TerminalSession.PendingPrompt
    /// Delivers the answer to whatever is waiting: a terminal session or a remote screen.
    let resolve: (PromptCoordinator.Decision) -> Void

    @State private var secret = ""
    @Environment(\.dismiss) private var dismiss

    init(prompt: TerminalSession.PendingPrompt, resolve: @escaping (PromptCoordinator.Decision) -> Void) {
        self.prompt = prompt
        self.resolve = resolve
    }

    init(session: TerminalSession, prompt: TerminalSession.PendingPrompt) {
        self.init(prompt: prompt) { session.resolvePrompt($0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch prompt {
                case let .unknownHostKey(identity, key):
                    unknownHostKey(identity: identity, key: key)
                case let .changedHostKey(identity, expected, presented):
                    changedHostKey(identity: identity, expected: expected, presented: presented)
                case let .password(username, host):
                    secretEntry(
                        title: String(localized: "Password"),
                        detail: String(localized: "for \(username)@\(host)"),
                        submit: { resolve(.password(secret)) }
                    )
                case let .keyPassphrase(keyName):
                    secretEntry(
                        title: String(localized: "Key passphrase"),
                        detail: String(localized: "to unlock \(keyName)"),
                        submit: { resolve(.passphrase(secret)) }
                    )
                case let .username(host):
                    usernameEntry(host: host)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        resolve(.reject)
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: - Host keys

    private func unknownHostKey(identity: KnownHostIdentity, key: SSHHostKey) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                Label(String(localized: "First connection to \(identity.displayName)"), systemImage: "questionmark.circle")
                    .font(DesignTokens.Typography.headline)

                Text(String(localized: "This server has not been seen before. Check that the fingerprint below matches the server."))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)

                FingerprintCard(title: String(localized: "Server fingerprint"), key: key, emphasis: .neutral)

                DisclosureGroup(String(localized: "How do I check this?")) {
                    Text(String(localized: "On the server, run:"))
                        .font(DesignTokens.Typography.caption)
                    Text("ssh-keygen -lf /etc/ssh/ssh_host_\(key.algorithm.replacingOccurrences(of: "ssh-", with: ""))_key.pub")
                        .font(DesignTokens.Typography.monoCaption)
                        .textSelection(.enabled)
                        .padding(DesignTokens.Spacing.sm)
                        .background(DesignTokens.Color.surfaceSecondary, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
                }
                .font(DesignTokens.Typography.callout)

                Button(String(localized: "Trust and Connect")) {
                    resolve(.approve)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .padding(DesignTokens.Spacing.lg)
        }
        .navigationTitle(String(localized: "Unknown host"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func changedHostKey(
        identity: KnownHostIdentity,
        expected: SSHHostKey,
        presented: SSHHostKey
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                Label(String(localized: "The host key has changed"), systemImage: "exclamationmark.shield.fill")
                    .font(DesignTokens.Typography.headline)
                    .foregroundStyle(DesignTokens.Color.danger)

                Text(String(localized: """
                \(identity.displayName) is presenting a different key from the one recorded. \
                This happens when a server is rebuilt or rekeyed — and it is also what an \
                interception attack looks like.
                """))
                .foregroundStyle(DesignTokens.Color.labelSecondary)

                FingerprintCard(title: String(localized: "Previously trusted"), key: expected, emphasis: .neutral)
                FingerprintCard(title: String(localized: "Presented now"), key: presented, emphasis: .danger)

                Text(String(localized: "Do not continue unless you know why the key changed."))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(DesignTokens.Color.danger)

                // Deliberately the less prominent of the two actions: Cancel is in the
                // toolbar as the default, and accepting a replacement is bordered rather
                // than filled so it does not read as the obvious tap.
                Button(String(localized: "Replace the stored key and connect"), role: .destructive) {
                    resolve(.approve)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
            .padding(DesignTokens.Spacing.lg)
        }
        .navigationTitle(String(localized: "Host key changed"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - User name

    /// Not a secret, so a plain field; the connection was saved without one on purpose
    /// and is asked each time (D-024).
    private func usernameEntry(host: String) -> some View {
        Form {
            Section {
                TextField(String(localized: "User name"), text: $secret)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .onSubmit {
                        guard !secret.isEmpty else { return }
                        resolve(.username(secret))
                        dismiss()
                    }
                    .accessibilityIdentifier("prompt-username")
            } header: {
                Text(String(localized: "for \(host)"))
            } footer: {
                Text(String(localized: "This connection has no user name saved. Edit the connection to save one."))
            }

            Button(String(localized: "Continue")) {
                resolve(.username(secret))
                dismiss()
            }
            .disabled(secret.isEmpty)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(String(localized: "User name"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Secrets

    private func secretEntry(title: String, detail: String, submit: @escaping () -> Void) -> some View {
        Form {
            Section {
                SecureField(title, text: $secret)
                    // Opts out of iOS Password AutoFill's "Save Password?" sheet, which would store
                    // this secret in iCloud Keychain passwords — the one place the policy says it never goes.
                    .textContentType(.oneTimeCode)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        submit()
                        dismiss()
                    }
            } header: {
                Text(detail)
            } footer: {
                Text(String(localized: "Entered secrets are held only for this connection unless you save them to the Keychain."))
            }

            Button(String(localized: "Continue")) {
                submit()
                dismiss()
            }
            .disabled(secret.isEmpty)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FingerprintCard: View {
    enum Emphasis {
        case neutral
        case danger
    }

    let title: String
    let key: SSHHostKey
    let emphasis: Emphasis

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
            Text(key.fingerprintSHA256)
                .font(DesignTokens.Typography.monoCaption)
                .textSelection(.enabled)
            Text(key.algorithm)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.labelTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                .fill(DesignTokens.Color.surfaceSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                .strokeBorder(
                    emphasis == .danger ? DesignTokens.Color.danger : Color.clear,
                    lineWidth: 1.5
                )
        )
    }
}
