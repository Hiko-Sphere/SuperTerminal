import STForwarding
import SwiftUI

/// The forwards on one connection: what they are, what they are doing, and the switch
/// (D-045).
///
/// It says out loud that a forward stops when the app does. iOS suspends an app that is
/// not on screen, and a suspended app's sockets stop being served — so a tunnel someone is
/// relying on can be quietly dead. Telling them here costs one sentence; not telling them
/// costs an afternoon of wondering why a database client stopped connecting.
struct PortForwardsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let session: TerminalSession

    @State private var editing: PortForward?
    @State private var isAdding = false

    /// Read from the store rather than from the session's copy of the host. The session
    /// holds the connection's description as it was when it opened; the rules are edited
    /// here and belong to the saved connection, and one place has to be the truth.
    private var rules: [PortForward] {
        container.hostStore.hosts.first { $0.id == session.host.id }?.portForwards ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                if rules.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Port Forwards"),
                        systemImage: "arrow.left.arrow.right",
                        description: Text("A forward carries a port on this device to a port the server can reach, or the other way round.")
                    )
                } else {
                    Section {
                        ForEach(rules) { rule in
                            PortForwardRow(
                                rule: rule,
                                snapshot: session.forwardStates[rule.id],
                                isConnected: session.isConnected,
                                start: { Task { await session.startForward(rule) } },
                                stop: { Task { await session.stopForward(rule.id) } },
                                edit: { editing = rule }
                            )
                        }
                        .onDelete(perform: delete)
                    } footer: {
                        Text("A forward runs only while Apex Terminal is running and this connection is open. Leaving the app for long enough suspends it, and the forward stops with it.")
                    }
                }
            }
            .navigationTitle(String(localized: "Port Forwards"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Add"), systemImage: "plus") { isAdding = true }
                        .accessibilityIdentifier("add-port-forward")
                }
            }
            .task {
                // Counters have no other way to move: nothing pushes them.
                while !Task.isCancelled {
                    await session.refreshForwardStates()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .navigationDestination(isPresented: $isAdding) {
                PortForwardEditorView(existing: nil) { save($0) }
            }
            .navigationDestination(item: $editing) { rule in
                PortForwardEditorView(existing: rule) { save($0) }
            }
        }
    }

    private func save(_ rule: PortForward) {
        guard var host = container.hostStore.hosts.first(where: { $0.id == session.host.id }) else { return }
        var rules = host.portForwards ?? []
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        host.portForwards = rules
        container.hostStore.update(host)
    }

    private func delete(_ offsets: IndexSet) {
        guard var host = container.hostStore.hosts.first(where: { $0.id == session.host.id }) else { return }
        var rules = host.portForwards ?? []
        let removed = offsets.map { rules[$0] }
        rules.remove(atOffsets: offsets)
        host.portForwards = rules.isEmpty ? nil : rules
        container.hostStore.update(host)
        // A rule that is gone must not go on running: the row it could be stopped from
        // has gone with it.
        Task { for rule in removed { await session.stopForward(rule.id) } }
    }
}

/// One rule, and what it is doing.
private struct PortForwardRow: View {
    let rule: PortForward
    let snapshot: PortForwardSnapshot?
    let isConnected: Bool
    let start: () -> Void
    let stop: () -> Void
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.displayName)
                        .font(DesignTokens.Typography.body)
                    Text(addresses)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                control
            }
            if let detail {
                Text(detail)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(isFailed ? DesignTokens.Color.warning : .secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("port-forward-row")
    }

    @ViewBuilder
    private var control: some View {
        switch snapshot?.state {
        case .starting:
            ProgressView()
        case .running:
            Button(String(localized: "Stop"), action: stop)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("stop-port-forward")
        default:
            Button(String(localized: "Start"), action: start)
                .buttonStyle(.bordered)
                .disabled(!isConnected)
                .accessibilityIdentifier("start-port-forward")
        }
    }

    /// The bound port, when it differs from the one asked for — a remote forward can ask
    /// the server to choose, and then the number that matters is the one it chose.
    private var addresses: String {
        guard case let .running(port) = snapshot?.state, port != rule.listenPort else {
            return rule.addressSummary
        }
        var bound = rule
        bound.listenPort = port
        return bound.addressSummary
    }

    private var isFailed: Bool {
        if case .failed = snapshot?.state { return true }
        return false
    }

    private var detail: String? {
        switch snapshot?.state {
        case let .failed(message, recovery):
            [message, recovery].compactMap { $0 }.joined(separator: " ")
        case .running:
            traffic
        default:
            nil
        }
    }

    private var traffic: String {
        let counts = snapshot?.traffic ?? PortForwardTraffic()
        let up = ByteCountFormatStyle().format(Int64(counts.bytesOut))
        let down = ByteCountFormatStyle().format(Int64(counts.bytesIn))
        return String(localized: "\(counts.openConnections) open · \(up) sent · \(down) received")
    }

    private var accessibilityLabel: String {
        switch snapshot?.state {
        case .running:
            String(localized: "\(rule.displayName), running, \(addresses)")
        case let .failed(message, _):
            String(localized: "\(rule.displayName), failed, \(message)")
        default:
            String(localized: "\(rule.displayName), stopped, \(addresses)")
        }
    }
}

/// `Int64` bytes as something short enough for a row.
private struct ByteCountFormatStyle {
    func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}
