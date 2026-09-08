import STSSH
import SwiftUI

/// The certificate attached to one key (D-046).
///
/// A certificate is a public document that says who a key speaks for and until when, so
/// this shows all of it: an authority's fingerprint to compare, the principals, and the
/// expiry. A certificate that has run out is the most common reason a key that worked
/// yesterday stops working, and it is worth being able to see that at a glance rather
/// than deducing it from "permission denied".
struct KeyCertificateView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let key: StoredKey

    @State private var pasted = ""
    @State private var problem: String?

    private var current: SSHCertificate? {
        container.hostStore.key(withID: key.id)?.certificate
    }

    var body: some View {
        Form {
            if let certificate = current {
                Section {
                    LabeledContent(String(localized: "Identity"), value: certificate.keyID)
                    LabeledContent(String(localized: "Speaks for"), value: principals(of: certificate))
                    if let validBefore = certificate.validBefore {
                        LabeledContent(String(localized: "Expires")) {
                            Text(validBefore, format: .dateTime)
                                .foregroundStyle(certificate.isValid() ? .primary : DesignTokens.Color.warning)
                        }
                    } else {
                        LabeledContent(String(localized: "Expires"), value: String(localized: "Never"))
                    }
                    LabeledContent(String(localized: "Signed by"), value: certificate.authorityFingerprintSHA256)
                        .font(DesignTokens.Typography.monoCaption)
                        .textSelection(.enabled)
                } header: {
                    Text("Certificate")
                } footer: {
                    if !certificate.isValid() {
                        Text("This certificate is outside its validity window, so it is not offered. The key itself is still offered on its own.")
                            .foregroundStyle(DesignTokens.Color.warning)
                    } else {
                        Text("Offered together with the key. The server checks it against its own authority instead of looking the key up in a file.")
                    }
                }

                Section {
                    Button(String(localized: "Remove Certificate"), role: .destructive) {
                        update(certificate: nil)
                    }
                    .accessibilityIdentifier("remove-certificate")
                }
            } else {
                Section {
                    TextEditor(text: $pasted)
                        .font(DesignTokens.Typography.monoCaption)
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("certificate-text")
                    Button(String(localized: "Attach Certificate")) { attach() }
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("attach-certificate")
                } header: {
                    Text("Certificate")
                } footer: {
                    Text("Paste the file `ssh-keygen -s` produced for this key — the one whose name ends in `-cert.pub`. It is public: it carries no secret and can be shown to anyone.")
                }
            }

            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .foregroundStyle(DesignTokens.Color.warning)
                        .font(DesignTokens.Typography.callout)
                }
            }
        }
        .navigationTitle(key.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func principals(of certificate: SSHCertificate) -> String {
        let principals = certificate.principals
        // An empty list means "anyone", which is worth spelling out: it is the most
        // permissive certificate there is and it does not look like it.
        return principals.isEmpty
            ? String(localized: "Any user (the certificate names none)")
            : principals.joined(separator: ", ")
    }

    private func attach() {
        do {
            let certificate = try SSHCertificate(openSSHRepresentation: pasted)
            guard certificate.kind == .user else {
                problem = String(localized: "That is a host certificate. A key is authenticated with a user certificate; a host certificate belongs to a server.")
                return
            }
            // The certificate has to be for *this* key, or it authenticates nothing —
            // and the server's refusal would say nothing about why.
            guard let certified = try? certificate.certifiedKey(),
                  let inner = try? SSHHostKey(certified.key),
                  inner.fingerprintSHA256 == key.fingerprintSHA256
            else {
                problem = String(localized: "That certificate was issued for a different key.")
                return
            }
            problem = nil
            pasted = ""
            update(certificate: certificate)
        } catch let error as SSHCertificateError {
            problem = error.stError.message
        } catch {
            problem = String(localized: "The certificate could not be read.")
        }
    }

    private func update(certificate: SSHCertificate?) {
        guard var stored = container.hostStore.key(withID: key.id) else { return }
        stored.certificate = certificate
        container.hostStore.upsert(stored)
    }
}
