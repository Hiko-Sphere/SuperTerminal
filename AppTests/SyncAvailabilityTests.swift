import Foundation
import STCore
import STSSH
import Testing
@testable import ApexTerminal

/// What "not available" has to mean, so that turning it back on is one line and turning
/// it off is not a half-measure (D-037).
@Suite struct SyncAvailabilityTests {
    @MainActor
    private func coordinator(enabledInDefaults: Bool) throws -> (SyncCoordinator, AppSettings) {
        let defaults = UserDefaults(suiteName: "sync-availability-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.iCloudSyncEnabled = enabledInDefaults
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("st-availability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tombstones = SyncTombstones(directory: directory)
        let store = AppSyncStore(
            hosts: HostStore(directory: directory),
            screens: ScreenStore(directory: directory),
            snippets: SnippetStore(directory: directory, settings: settings),
            knownHosts: InMemoryKnownHostsStore(),
            tombstones: tombstones
        )
        return (
            SyncCoordinator(
                settings: settings,
                directory: directory,
                local: store,
                tombstones: tombstones,
                log: .disabled
            ),
            settings
        )
    }

    @Test("A preference left over from a build that offered it does not start an engine")
    @MainActor func staleSettingDoesNotStart() throws {
        // Someone who turned sync on before it was withdrawn must not get an engine that
        // can only fail — and must not be told it is running.
        let (sync, _) = try coordinator(enabledInDefaults: true)
        #expect(sync.isEnabled == SyncAvailability.isAvailable,
                "an engine exists only when syncing is actually available")
    }

    @Test("Asking to turn it on does nothing while it is unavailable")
    @MainActor func turningOnIsRefused() throws {
        let (sync, settings) = try coordinator(enabledInDefaults: false)
        sync.setEnabled(true)
        if SyncAvailability.isAvailable {
            #expect(sync.isEnabled)
        } else {
            #expect(!sync.isEnabled, "no engine")
            #expect(!settings.iCloudSyncEnabled, "and the preference is not quietly set either")
        }
    }

    @Test("Withdrawing it is a switch, not a deletion")
    func theEngineIsStillThere() {
        // The point of a flag rather than a rip-out: everything below it still exists and
        // is still tested, so turning it back on is one line rather than a rewrite.
        #expect(!SyncAvailability.unavailableReason.isEmpty)
        #expect(SyncKind.allCases.count >= 5, "the record kinds are still modelled")
    }
}
