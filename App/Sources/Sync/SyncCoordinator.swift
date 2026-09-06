import CloudKit
import Foundation
import Observation
import STCore
import STSSH

/// Owns the iCloud switch.
///
/// The CloudKit transport builds a `CKSyncEngine` the moment it exists, which registers
/// for push and starts talking to the container. That must not happen on every launch
/// of an app whose users mostly never turn the feature on, so the transport is created
/// when the switch goes on and released when it goes off.
@Observable
@MainActor
final class SyncCoordinator {
    enum Account: Equatable, Sendable {
        case unknown
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
        case undetermined(String)
    }

    private(set) var engine: SyncEngine?
    private(set) var account: Account = .unknown

    private let settings: AppSettings
    private let directory: URL
    private let local: AppSyncStore
    private let tombstones: SyncTombstones
    private let log: STLogger
    private var pending: Task<Void, Never>?

    var isEnabled: Bool { engine != nil }

    init(settings: AppSettings, directory: URL, local: AppSyncStore, tombstones: SyncTombstones, log: STLogger) {
        self.settings = settings
        self.directory = directory
        self.local = local
        self.tombstones = tombstones
        self.log = log
        // A preference left over from a build where the switch existed must not start
        // an engine that cannot succeed (D-037).
        if settings.iCloudSyncEnabled, SyncAvailability.isAvailable { start() }
    }

    /// Turning sync off stops syncing and nothing more: data already in iCloud stays
    /// there until the user asks for it to be removed, which is a separate action.
    func setEnabled(_ enabled: Bool) {
        guard SyncAvailability.isAvailable else { return }
        settings.iCloudSyncEnabled = enabled
        if enabled { start() } else { stop() }
    }

    /// Coalesces bursts of local edits into one reconciliation.
    func scheduleSync() {
        guard engine != nil else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        await engine?.sync()
    }

    /// A trusted host key removed by hand must stay removed on every device: without a
    /// tombstone the other device's copy would come straight back on the next pull.
    /// Hosts and snippets record theirs inside their stores; known hosts live in the
    /// package store, which knows nothing about sync, so the screen reports it here.
    func recordDeletion(ofKnownHost identity: KnownHostIdentity) {
        tombstones.record(SyncKey(kind: .knownHost, id: AppSyncStore.knownHostID(identity)))
        scheduleSync()
    }

    func handleForeground() {
        guard engine != nil else { return }
        refreshAccount()
        scheduleSync()
    }

    /// Removes the app's data from iCloud and forgets local deletion history, which
    /// only existed to be sent up.
    func purgeRemote() async throws {
        try await engine?.purgeRemote()
        tombstones.removeAll()
    }

    private func start() {
        guard engine == nil else { return }
        let transport = CloudKitSyncTransport(stateDirectory: directory)
        let engine = SyncEngine(transport: transport, local: local)
        #if DEBUG
        engine.diagnosticsDirectory = directory
        #endif
        self.engine = engine
        log.info("iCloud sync enabled")
        refreshAccount()
        scheduleSync()
    }

    private func stop() {
        pending?.cancel()
        pending = nil
        engine = nil
        account = .unknown
        log.info("iCloud sync disabled")
    }

    private func refreshAccount() {
        Task { [weak self] in
            let status: Account
            do {
                switch try await CKContainer(identifier: CloudKitSyncTransport.containerIdentifier).accountStatus() {
                case .available: status = .available
                case .noAccount: status = .noAccount
                case .restricted: status = .restricted
                case .temporarilyUnavailable: status = .temporarilyUnavailable
                case .couldNotDetermine: status = .undetermined(String(localized: "Could not determine the iCloud account state."))
                @unknown default: status = .undetermined(String(localized: "Unknown iCloud account state."))
                }
            } catch {
                // Through the same translation as a sync failure (D-032). This path was
                // missed, and it is the one that put "<CKError 0x127531e60: …>" on screen:
                // a pointer address, in the place that is supposed to say what to do.
                status = .undetermined(SyncFailure.describe(error))
                #if DEBUG
                if let directory = await self?.directory { SyncDiagnostics.record(error, in: directory) }
                #endif
            }
            self?.account = status
        }
    }
}
