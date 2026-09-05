import CloudKit
import Foundation
import Observation
import STCore

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
        if settings.iCloudSyncEnabled { start() }
    }

    /// Turning sync off stops syncing and nothing more: data already in iCloud stays
    /// there until the user asks for it to be removed, which is a separate action.
    func setEnabled(_ enabled: Bool) {
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
        engine = SyncEngine(transport: transport, local: local)
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
                status = .undetermined(String(describing: error))
            }
            self?.account = status
        }
    }
}
