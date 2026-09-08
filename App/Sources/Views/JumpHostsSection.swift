import SwiftUI

/// The connections to hop through before reaching this one (D-047).
///
/// A chain is built from *saved connections* rather than typed addresses, and that is the
/// design decision worth stating: each hop then has its own credentials and its own host
/// key record, so a bastion is checked as carefully as the destination and a compromised
/// one cannot stand in for it. It also means a hop set up once is reused everywhere.
struct JumpHostsSection: View {
    @Environment(AppContainer.self) private var container
    let hostID: UUID?
    @Binding var jumpHosts: [UUID]

    private var candidates: [Host] {
        // A connection cannot jump through itself, and a hop already in the chain is not
        // offered twice: both would be silently ignored when connecting, and an option
        // that does nothing is worse than one that is absent.
        container.hostStore.hosts.filter { $0.id != hostID && !jumpHosts.contains($0.id) }
    }

    var body: some View {
        Section {
            ForEach(Array(jumpHosts.enumerated()), id: \.element) { index, id in
                if let hop = container.hostStore.hosts.first(where: { $0.id == id }) {
                    HStack {
                        Text("\(index + 1)")
                            .font(DesignTokens.Typography.monoCaption)
                            .foregroundStyle(DesignTokens.Color.labelTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hop.name)
                            Text("\(hop.username)@\(hop.hostname):\(String(hop.port))")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Color.labelSecondary)
                        }
                    }
                    .accessibilityIdentifier("jump-host-row")
                } else {
                    // The connection it named has been deleted. Shown rather than dropped
                    // silently, because a chain quietly getting shorter changes where the
                    // traffic goes.
                    Label(String(localized: "A deleted connection"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DesignTokens.Color.warning)
                }
            }
            .onDelete { jumpHosts.remove(atOffsets: $0) }
            .onMove { jumpHosts.move(fromOffsets: $0, toOffset: $1) }

            if !candidates.isEmpty {
                Menu {
                    ForEach(candidates) { candidate in
                        Button(candidate.name) { jumpHosts.append(candidate.id) }
                    }
                } label: {
                    Label(String(localized: "Add a jump host"), systemImage: "plus")
                }
                .accessibilityIdentifier("add-jump-host")
            }
        } header: {
            Text("Jump hosts")
        } footer: {
            Text(jumpHosts.isEmpty
                ? String(localized: "Connect through one or more saved connections, in order — the equivalent of `ssh -J`. Each hop is a connection of its own: its own credentials, and its own host key checked against its own record.")
                : String(localized: "Connected in the order listed, then on to this server. The last hop carries the traffic without being able to read it: the session is encrypted between this device and the destination."))
        }
    }
}
