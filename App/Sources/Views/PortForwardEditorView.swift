import STForwarding
import SwiftUI

/// Creating or changing one forwarding rule (D-045).
///
/// The three kinds are genuinely different things, so the form changes shape rather than
/// showing every field and letting the user work out which apply: a dynamic forward has no
/// destination to enter, and only a remote forward can ask the server to pick a port.
///
/// Pushed rather than presented. A sheet on top of a sheet is cramped, and its fields did
/// not reliably take keyboard focus — a tap would land and nothing would be typed.
struct PortForwardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let existing: PortForward?
    let save: (PortForward) -> Void

    @State private var name = ""
    @State private var kind: PortForward.Kind = .local
    @State private var listenPort = ""
    @State private var targetHost = ""
    @State private var targetPort = ""
    @State private var remoteBindHost = "127.0.0.1"
    @State private var startsAutomatically = false
    @FocusState private var focused: Field?

    /// The fields that raise a keyboard. Named so the Done button above the keyboard has
    /// something to clear — a number pad has no return key, so without it the keyboard
    /// covers the Save button and there is no way to put it away.
    private enum Field: Hashable { case name, listenPort, remoteBindHost, targetHost, targetPort }

    var body: some View {
        Group {
            Form {
                Section {
                    Picker(String(localized: "Kind"), selection: $kind) {
                        Text("Local").tag(PortForward.Kind.local)
                        Text("Remote").tag(PortForward.Kind.remote)
                        Text("Dynamic (SOCKS5)").tag(PortForward.Kind.dynamic)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("port-forward-kind")
                } footer: {
                    Text(kindExplanation)
                }

                // One block, in the order the rule reads: what it is called, where it
                // listens, where that goes. Split across sections the destination sat
                // under the keyboard the first field raises, which is a real nuisance on
                // a phone and not only in a test.
                Section {
                    TextField(String(localized: "Name"), text: $name)
                        .focused($focused, equals: .name)
                    TextField(listenPortLabel, text: $listenPort)
                        .keyboardType(.numberPad)
                        .focused($focused, equals: .listenPort)
                        .accessibilityIdentifier("port-forward-listen-port")
                    if kind == .remote {
                        TextField(String(localized: "Address the server binds"), text: $remoteBindHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused, equals: .remoteBindHost)
                    }
                    if kind != .dynamic {
                        TextField(String(localized: "Destination host"), text: $targetHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused, equals: .targetHost)
                            .accessibilityIdentifier("port-forward-target-host")
                        TextField(String(localized: "Destination port"), text: $targetPort)
                            .keyboardType(.numberPad)
                            .focused($focused, equals: .targetPort)
                            .accessibilityIdentifier("port-forward-target-port")
                    }
                } footer: {
                    if kind == .remote {
                        Text("Leave the address as 127.0.0.1 unless the server's sshd sets GatewayPorts — without it, a request to bind anything else is refused. Port 0 asks the server to choose.")
                    }
                }

                Section {
                    Toggle(String(localized: "Start with the connection"), isOn: $startsAutomatically)
                }

                if !draft.validationProblems.isEmpty {
                    Section(String(localized: "Before you can save")) {
                        ForEach(draft.validationProblems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.circle")
                                .foregroundStyle(DesignTokens.Color.warning)
                                .font(DesignTokens.Typography.callout)
                        }
                    }
                }
            }
            .navigationTitle(existing == nil
                ? String(localized: "New Forward")
                : String(localized: "Edit Forward"))
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "Done")) { focused = nil }
                        .accessibilityIdentifier("port-forward-keyboard-done")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        save(draft)
                        dismiss()
                    }
                    .disabled(!draft.validationProblems.isEmpty)
                    .accessibilityIdentifier("save-port-forward")
                }
            }
            .task { load() }
        }
    }

    private var listenPortLabel: String {
        kind == .remote
            ? String(localized: "Port on the server")
            : String(localized: "Port on this device")
    }

    private var kindExplanation: String {
        switch kind {
        case .local:
            String(localized: "This device listens. Anything that connects is carried through the server to the destination — the way to reach a database that only the server can see.")
        case .remote:
            String(localized: "The server listens. Anything that connects to it there is carried back to a destination this device can reach.")
        case .dynamic:
            String(localized: "This device listens as a SOCKS5 proxy. Each client picks its own destination, which the server then connects to — one rule instead of one per address.")
        }
    }

    private var draft: PortForward {
        PortForward(
            id: existing?.id ?? UUID(),
            name: name,
            kind: kind,
            listenPort: Int(listenPort.trimmingCharacters(in: .whitespaces)) ?? -1,
            targetHost: targetHost.trimmingCharacters(in: .whitespaces),
            targetPort: Int(targetPort.trimmingCharacters(in: .whitespaces)) ?? -1,
            remoteBindHost: remoteBindHost.trimmingCharacters(in: .whitespaces),
            startsAutomatically: startsAutomatically
        )
    }

    private func load() {
        guard let existing else { return }
        name = existing.name
        kind = existing.kind
        listenPort = String(existing.listenPort)
        targetHost = existing.targetHost
        targetPort = existing.targetPort > 0 ? String(existing.targetPort) : ""
        remoteBindHost = existing.remoteBindHost
        startsAutomatically = existing.startsAutomatically
    }
}
