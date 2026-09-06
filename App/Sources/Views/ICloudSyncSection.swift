import SwiftUI

/// The iCloud switch, its state, and the host-key disagreements it is holding.
struct ICloudSyncSection: View {
    @Environment(AppContainer.self) private var container
    @State private var confirmingRemoval = false
    @State private var removalError: String?

    var body: some View {
        Section {
            Toggle("Sync with iCloud", isOn: enabledBinding)
                .accessibilityIdentifier("icloud-toggle")
                // Shown rather than hidden: someone looking for sync should find out
                // where it stands, not be left wondering whether they missed it (D-037).
                .disabled(!SyncAvailability.isAvailable)
            if let engine = container.sync.engine {
                LabeledContent("Status") { Text(statusText(engine)) }
                    .font(DesignTokens.Typography.caption)
                ForEach(Array(engine.conflicts.keys).sorted { $0.id < $1.id }, id: \.self) { key in
                    conflictRow(key, engine: engine)
                }
                Button("Sync now") { Task { await container.sync.syncNow() } }
                    .disabled(engine.status == .syncing)
                Button("Remove my data from iCloud", role: .destructive) { confirmingRemoval = true }
            }
            if let removalError {
                Label(removalError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DesignTokens.Color.danger)
            }
        } header: {
            Text("iCloud")
        } footer: {
            if SyncAvailability.isAvailable {
                Text("Syncs connections, key names and public keys, snippets and trusted host keys between your devices through your own iCloud account. Private keys are added to iCloud Keychain only when you choose that for a key, and keys protected by Face ID or Touch ID never leave this device. Passwords, command history and diagnostics are not synced.")
            } else {
                Text(SyncAvailability.unavailableReason)
            }
        }
        .confirmationDialog(
            "Remove the app's data from iCloud?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove from iCloud", role: .destructive) {
                Task {
                    do {
                        try await container.sync.purgeRemote()
                        removalError = nil
                    } catch {
                        removalError = String(describing: error)
                    }
                }
            }
        } message: {
            Text("Everything this app stored in your iCloud account is deleted. Data on this device stays. Other devices keep their copies until they sync.")
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            // Off, whatever a previous build left stored: the switch must not read as on
            // while nothing is syncing.
            get: { SyncAvailability.isAvailable && container.settings.iCloudSyncEnabled },
            set: { container.sync.setEnabled($0) }
        )
    }

    private func statusText(_ engine: SyncEngine) -> String {
        switch container.sync.account {
        case .noAccount: return String(localized: "Not signed in to iCloud on this device.")
        case .restricted: return String(localized: "iCloud is restricted on this device.")
        case .temporarilyUnavailable: return String(localized: "iCloud is temporarily unavailable.")
        case let .undetermined(reason): return reason
        case .unknown, .available: break
        }
        switch engine.status {
        case .syncing: return String(localized: "Syncing…")
        case let .failed(reason): return String(localized: "Last sync failed: \(reason)")
        case .idle:
            if let last = engine.lastSynced {
                return String(localized: "Last synced \(last.formatted(.relative(presentation: .named)))")
            }
            return String(localized: "Not synced yet.")
        }
    }

    @ViewBuilder
    private func conflictRow(_ key: SyncKey, engine: SyncEngine) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Label("Another device trusts a different key for \(key.id)", systemImage: "exclamationmark.shield")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.warning)
            HStack {
                Button("Keep this device's key") { engine.keepLocal(key) }
                Button("Use the other device's key") { Task { try? await engine.acceptConflict(key) } }
            }
            .font(DesignTokens.Typography.caption)
            .buttonStyle(.bordered)
        }
    }
}
