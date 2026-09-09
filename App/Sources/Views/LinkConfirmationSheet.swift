import STCore
import SwiftUI

/// What a link wants to do, before it does it (D-061).
///
/// The whole point of this screen is that it is *specific*: the server it will connect to,
/// spelled out, and the command it will run, verbatim and monospaced. A dialogue that said
/// "a link wants to open a connection. Allow?" would train people to tap Allow.
struct LinkConfirmationSheet: View {
    let pending: LinkCoordinator.Pending
    let onApprove: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(headline, systemImage: symbol)
                        .font(DesignTokens.Typography.headline)
                        .foregroundStyle(DesignTokens.Color.label)
                } footer: {
                    Text(explanation)
                }

                Section("Server") {
                    LabeledContent("Name", value: serverName)
                    LabeledContent("Address", value: serverAddress)
                    if let user = username, !user.isEmpty {
                        LabeledContent("User", value: user)
                    }
                }

                if let command = pending.command {
                    Section {
                        // Monospaced and selectable: this is the thing being decided about,
                        // and a command that is hard to read is a command nobody read.
                        Text(command)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("link-command")
                    } header: {
                        Text("Command")
                    } footer: {
                        Text("This will be typed into the session as if you had typed it. Read it before you allow it.")
                    }
                }
            }
            .navigationTitle("Open this link?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        onCancel()
                        dismiss()
                    }
                    .accessibilityIdentifier("link-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pending.command == nil ? "Open" : "Run") {
                        onApprove()
                        dismiss()
                    }
                    .accessibilityIdentifier("link-approve")
                }
            }
        }
        .accessibilityIdentifier("link-confirmation")
    }

    private var symbol: String {
        pending.command == nil ? "link" : "terminal"
    }

    private var headline: String {
        switch pending.reason {
        case .unknownServer: String(localized: "A link wants to connect to a server you have not saved")
        case .runsACommand: String(localized: "A link wants to run a command")
        }
    }

    private var explanation: String {
        switch pending.reason {
        case .unknownServer:
            String(localized: "Links can come from anywhere — a web page, a message, a code on a wall. Check the server below is one you meant to reach. Opening it adds nothing to your connections until you save it.")
        case .runsACommand:
            String(localized: "Links can come from anywhere — a web page, a message, a code on a wall. Nothing is sent to the server until you allow it.")
        }
    }

    private var serverName: String {
        pending.existing?.name ?? String(localized: "Not saved on this device")
    }

    private var serverAddress: String {
        if let host = pending.existing { return "\(host.hostname):\(host.port)" }
        guard let address = pending.address else { return "—" }
        return address.port.map { "\(address.host):\($0)" } ?? address.host
    }

    private var username: String? {
        pending.existing?.username ?? pending.address?.username
    }
}
