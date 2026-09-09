import Foundation
import STCore
import STSSH

/// Reading and writing backups, and saying what an import would do before it does it
/// (D-040).
///
/// Nothing here writes to a store until the user has seen the summary and chosen. An
/// import that silently merged, or silently replaced, would be the same operation with
/// two very different outcomes and no way to tell them apart afterwards.
@MainActor
final class BackupService {
    /// What an import would change, worked out without changing anything.
    struct Preview: Equatable {
        var hosts = Counts()
        var screens = Counts()
        var snippets = Counts()
        var keys = Counts()
        var knownHosts = Counts()
        var privateKeys = 0
        var carriesSettings = false

        struct Counts: Equatable {
            var new = 0
            /// Records whose id already exists here. What happens to them is the user's
            /// choice, which is why they are counted separately.
            var existing = 0
            var total: Int { new + existing }
        }

        var isEmpty: Bool {
            hosts.total + screens.total + snippets.total + keys.total + knownHosts.total == 0
                && !carriesSettings
        }
        var conflicts: Int { hosts.existing + screens.existing + snippets.existing + keys.existing + knownHosts.existing }
    }

    /// What to do with records that already exist.
    enum Resolution: String, CaseIterable, Identifiable {
        /// Add what is new, leave what is here alone.
        case keepExisting
        /// Add what is new, overwrite what collides.
        case overwrite
        var id: String { rawValue }
    }

    struct Options {
        var includePrivateKeys = false
        var password: String = ""
    }

    /// Keys whose private half cannot leave the device, with the reason.
    struct Unexportable: Equatable {
        var name: String
        var reason: String
    }

    private let hosts: HostStore
    private let screens: ScreenStore
    private let snippets: SnippetStore
    private let knownHosts: any KnownHostsStore
    private let settings: AppSettings
    private let vault: CredentialVault
    private let log: STLogger

    init(
        hosts: HostStore,
        screens: ScreenStore,
        snippets: SnippetStore,
        knownHosts: any KnownHostsStore,
        settings: AppSettings,
        vault: CredentialVault,
        log: STLogger
    ) {
        self.hosts = hosts
        self.screens = screens
        self.snippets = snippets
        self.knownHosts = knownHosts
        self.settings = settings
        self.vault = vault
        self.log = log
    }

    // MARK: - Export

    /// The keys that cannot be included, so the export sheet can say so before the user
    /// chooses rather than after.
    func unexportableKeys() -> [Unexportable] {
        hosts.keys.compactMap { key in
            // The enclave reason comes first because it is the stronger fact: a biometric
            // Keychain key could in principle be exported after a prompt and is withheld
            // by policy, while an enclave key has no exportable form at all.
            if key.isHeldInSecureEnclave {
                return Unexportable(
                    name: key.name,
                    reason: String(localized: "Held in the Secure Enclave. Its private half has no exportable form and cannot be backed up or moved.")
                )
            }
            if key.requiresBiometrics {
                return Unexportable(
                    name: key.name,
                    reason: String(localized: "Protected by Face ID or Touch ID, so its private half cannot leave this device.")
                )
            }
            return nil
        }
    }

    func makeDocument(options: Options) throws -> BackupDocument {
        var payload = BackupDocument.Payload(
            hosts: hosts.hosts,
            screens: screens.screens,
            snippets: snippets.snippets,
            keys: hosts.keys,
            knownHosts: [],
            settings: currentSettings()
        )

        if options.includePrivateKeys {
            // A key held behind a biometric check is deliberately skipped rather than
            // prompting for each one: the point of that protection is that the private
            // half does not leave, and an export is exactly it leaving.
            for key in hosts.keys where !key.requiresBiometrics && key.isExportable {
                guard let pem = try? vault.loadPrivateKey(id: key.id, prompt: nil) else { continue }
                payload.privateKeys.append(.init(keyID: key.id, openSSHPrivateKey: pem))
            }
        }

        var document = BackupDocument(
            formatVersion: BackupDocument.currentFormatVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.shortVersion,
            payload: nil,
            sealed: nil
        )

        if options.password.isEmpty {
            guard !options.includePrivateKeys else {
                throw BackupError.damaged("private keys cannot be exported without a password")
            }
            document.payload = payload
        } else {
            // With a password the whole payload is sealed, not just the secrets: the list
            // of servers someone connects to is itself worth protecting.
            let plaintext = try Self.encoder.encode(payload)
            document.sealed = try BackupCrypto.seal(plaintext, password: options.password)
        }
        log.info("backup written", ["encrypted": "\(document.isEncrypted)", "privateKeys": "\(payload.privateKeys.count)"])
        return document
    }

    func knownHostEntries() async -> [KnownHostEntry] {
        (try? await knownHosts.all()) ?? []
    }

    /// Writes atomically, so an interrupted export leaves either the previous file or
    /// nothing — never half a backup that looks importable.
    func write(_ document: BackupDocument, to url: URL) throws {
        let data = try Self.encoder.encode(document)
        try data.write(to: url, options: .atomicAndProtected)
    }

    // MARK: - Import

    func read(_ data: Data) throws -> BackupDocument {
        let document: BackupDocument
        do {
            document = try Self.decoder.decode(BackupDocument.self, from: data)
        } catch {
            throw BackupError.notABackup
        }
        guard document.formatVersion <= BackupDocument.currentFormatVersion else {
            throw BackupError.fromANewerVersion(document.formatVersion)
        }
        guard document.payload != nil || document.sealed != nil else {
            throw BackupError.damaged("it carries no records")
        }
        return document
    }

    /// The records inside, unsealing first when the file is encrypted.
    func payload(of document: BackupDocument, password: String?) throws -> BackupDocument.Payload {
        if let sealed = document.sealed {
            guard let password, !password.isEmpty else { throw BackupError.needsPassword }
            let plaintext = try BackupCrypto.open(sealed, password: password)
            do {
                return try Self.decoder.decode(BackupDocument.Payload.self, from: plaintext)
            } catch {
                throw BackupError.damaged("the contents did not survive decryption")
            }
        }
        guard let payload = document.payload else { throw BackupError.damaged("it carries no records") }
        return migrate(payload, from: document.formatVersion)
    }

    /// Forward migration. Version 1 is the first, so there is nothing to move yet; the
    /// hook exists so the next change has somewhere to go rather than being bolted on.
    private func migrate(_ payload: BackupDocument.Payload, from version: Int) -> BackupDocument.Payload {
        payload
    }

    func preview(_ payload: BackupDocument.Payload, existingKnownHosts: [KnownHostEntry]) -> Preview {
        var preview = Preview()
        preview.hosts = counts(payload.hosts.map(\.id), against: Set(hosts.hosts.map(\.id)))
        preview.screens = counts(payload.screens.map(\.id), against: Set(screens.screens.map(\.id)))
        preview.snippets = counts(payload.snippets.map(\.id), against: Set(snippets.snippets.map(\.id)))
        preview.keys = counts(payload.keys.map(\.id), against: Set(hosts.keys.map(\.id)))
        let existing = Set(existingKnownHosts.map(Self.knownHostKey))
        preview.knownHosts = counts(payload.knownHosts.map(Self.knownHostKey), against: existing)
        preview.privateKeys = payload.privateKeys.count
        preview.carriesSettings = payload.settings != BackupDocument.Settings()
        return preview
    }

    private func counts<ID: Hashable>(_ incoming: [ID], against existing: Set<ID>) -> Preview.Counts {
        var counts = Preview.Counts()
        // A file that lists the same id twice counts it once: the second is the same
        // record, not a second one to add.
        for id in Set(incoming) {
            if existing.contains(id) { counts.existing += 1 } else { counts.new += 1 }
        }
        return counts
    }

    private static func knownHostKey(_ entry: KnownHostEntry) -> String {
        "\(entry.identity.host):\(entry.identity.port)|\(entry.identity.jumpDestination ?? "")"
    }

    /// Puts the records back. Returns how many were actually written.
    @discardableResult
    func apply(_ payload: BackupDocument.Payload, resolution: Resolution) async -> Preview {
        var applied = Preview()
        applied.hosts = restore(payload.hosts, existing: hosts.hosts.map(\.id), resolution: resolution) { host, isNew in
            if isNew { hosts.add(host) } else { hosts.update(host) }
        }
        applied.screens = restore(payload.screens, existing: screens.screens.map(\.id), resolution: resolution) { screen, isNew in
            if isNew { screens.add(screen) } else { screens.update(screen) }
        }
        applied.snippets = restore(payload.snippets, existing: snippets.snippets.map(\.id), resolution: resolution) { snippet, isNew in
            if isNew { snippets.add(snippet) } else { snippets.update(snippet) }
        }
        applied.keys = restore(payload.keys, existing: hosts.keys.map(\.id), resolution: resolution) { key, _ in
            hosts.upsert(key)
        }

        // A private key only goes back for a key record that is actually here, so a
        // half-applied import cannot leave a secret with nothing pointing at it.
        let known = Set(hosts.keys.map(\.id))
        for backup in payload.privateKeys where known.contains(backup.keyID) {
            try? vault.storePrivateKey(backup.openSSHPrivateKey, id: backup.keyID, requireBiometrics: false)
            applied.privateKeys += 1
        }

        for entry in payload.knownHosts {
            try? await knownHosts.store(entry)
            applied.knownHosts.new += 1
        }

        if payload.settings != BackupDocument.Settings() {
            restore(payload.settings)
            applied.carriesSettings = true
        }
        log.info("backup applied", ["resolution": resolution.rawValue])
        return applied
    }

    private func restore<T: Identifiable>(
        _ incoming: [T],
        existing: [T.ID],
        resolution: Resolution,
        write: (T, Bool) -> Void
    ) -> Preview.Counts {
        var counts = Preview.Counts()
        let existing = Set(existing)
        var seen = Set<T.ID>()
        for record in incoming {
            guard seen.insert(record.id).inserted else { continue }
            if existing.contains(record.id) {
                guard resolution == .overwrite else { continue }
                write(record, false)
                counts.existing += 1
            } else {
                write(record, true)
                counts.new += 1
            }
        }
        return counts
    }

    // MARK: - Settings

    private func currentSettings() -> BackupDocument.Settings {
        BackupDocument.Settings(
            themeID: settings.themeID,
            lightThemeID: settings.lightThemeID,
            followSystemAppearance: settings.followSystemAppearance,
            fontSize: settings.fontSize,
            scrollbackLimit: settings.scrollbackLimit,
            customThemes: settings.customThemes,
            keyRowVisible: settings.keyRowVisible,
            cursorBlink: settings.cursorBlink,
            bellEnabled: settings.bellEnabled,
            automaticReconnect: settings.automaticReconnect,
            confirmMultilinePaste: settings.confirmMultilinePaste,
            hideContentInAppSwitcher: settings.hideContentInAppSwitcher
        )
    }

    private func restore(_ backup: BackupDocument.Settings) {
        if let value = backup.themeID { settings.themeID = value }
        if let value = backup.lightThemeID { settings.lightThemeID = value }
        if let value = backup.followSystemAppearance { settings.followSystemAppearance = value }
        if let value = backup.fontSize { settings.fontSize = value }
        if let value = backup.scrollbackLimit { settings.scrollbackLimit = value }
        if !backup.customThemes.isEmpty { settings.customThemes = backup.customThemes }
        if let value = backup.keyRowVisible { settings.keyRowVisible = value }
        if let value = backup.cursorBlink { settings.cursorBlink = value }
        if let value = backup.bellEnabled { settings.bellEnabled = value }
        if let value = backup.automaticReconnect { settings.automaticReconnect = value }
        if let value = backup.confirmMultilinePaste { settings.confirmMultilinePaste = value }
        if let value = backup.hideContentInAppSwitcher { settings.hideContentInAppSwitcher = value }
    }

    // MARK: - Coding

    nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted so two exports of the same state are the same bytes, which makes a
        // backup diffable and a test able to compare files rather than objects.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
