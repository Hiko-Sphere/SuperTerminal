import Foundation
import STCore
import STSSH
import Testing
@testable import ApexTerminal

/// Backup, restore, and the ways a backup goes wrong (D-040).
///
/// The point of this feature is the day someone's phone is gone, so the tests that matter
/// are the unhappy ones: a truncated file, a wrong password, a file from a version that
/// does not exist yet, and the same record listed twice.
@Suite struct BackupTests {
    @MainActor
    private func service() throws -> (BackupService, HostStore, SnippetStore, ScreenStore, AppSettings) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "backup-\(UUID())")!)
        let hosts = HostStore(directory: directory)
        let snippets = SnippetStore(directory: directory, settings: settings)
        let screens = ScreenStore(directory: directory)
        let vault = CredentialVault()
        let service = BackupService(
            hosts: hosts, screens: screens, snippets: snippets,
            knownHosts: InMemoryKnownHostsStore(), settings: settings, vault: vault, log: .disabled
        )
        return (service, hosts, snippets, screens, settings)
    }

    private func host(_ name: String, id: UUID = UUID()) -> Host {
        Host(id: id, name: name, hostname: "example.invalid", username: "u", credentials: [.none])
    }

    // MARK: - The ordinary path

    @Test("An export carries the records and no secret, and restores on an empty device")
    @MainActor func roundTrip() throws {
        let (service, hosts, _, _, _) = try service()
        hosts.add(host("build"))
        hosts.add(host("db"))

        let document = try service.makeDocument(options: .init())
        #expect(!document.isEncrypted, "no password means no encryption, and no secrets to protect")
        let data = try BackupService.encoder.encode(document)

        // Nothing that could be a credential is in the file. Checked on the bytes, because
        // that is what leaves the device.
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("PRIVATE KEY"))
        #expect(!text.lowercased().contains("\"password\""))

        // A fresh device reads it back.
        let (fresh, freshHosts, _, _, _) = try self.service()
        let read = try fresh.read(data)
        let payload = try fresh.payload(of: read, password: nil)
        #expect(payload.hosts.count == 2)
        #expect(freshHosts.hosts.isEmpty, "reading changes nothing on its own")
    }

    @Test("The preview says what would happen before anything happens")
    @MainActor func previewIsHonestAndChangesNothing() async throws {
        let (service, hosts, _, _, _) = try service()
        let shared = UUID()
        hosts.add(host("build", id: shared))
        var payload = BackupDocument.Payload()
        payload.hosts = [host("build renamed", id: shared), host("new")]

        let preview = service.preview(payload, existingKnownHosts: [])
        #expect(preview.hosts.new == 1)
        #expect(preview.hosts.existing == 1)
        #expect(preview.conflicts == 1)
        #expect(hosts.hosts.count == 1, "previewing is not importing")
        #expect(hosts.hosts.first?.name == "build")
    }

    @Test("Keeping what is here adds only the new; overwriting replaces the collision")
    @MainActor func resolution() async throws {
        let shared = UUID()
        var payload = BackupDocument.Payload()
        payload.hosts = [host("from backup", id: shared), host("new")]

        let (keep, keepHosts, _, _, _) = try service()
        keepHosts.add(host("mine", id: shared))
        await keep.apply(payload, resolution: .keepExisting)
        #expect(keepHosts.hosts.count == 2)
        #expect(keepHosts.hosts.first(where: { $0.id == shared })?.name == "mine", "left alone")

        let (over, overHosts, _, _, _) = try service()
        overHosts.add(host("mine", id: shared))
        await over.apply(payload, resolution: .overwrite)
        #expect(overHosts.hosts.count == 2)
        #expect(overHosts.hosts.first(where: { $0.id == shared })?.name == "from backup", "replaced")
    }

    @Test("The same record twice in one file is one record, not two")
    @MainActor func duplicatesWithinTheFile() async throws {
        let (service, hosts, _, _, _) = try service()
        let twice = UUID()
        var payload = BackupDocument.Payload()
        payload.hosts = [host("a", id: twice), host("a again", id: twice)]

        let preview = service.preview(payload, existingKnownHosts: [])
        #expect(preview.hosts.new == 1, "counted once")
        await service.apply(payload, resolution: .keepExisting)
        #expect(hosts.hosts.count == 1, "and written once")
    }

    // MARK: - Secrets

    @Test("A password seals everything, not only the keys")
    @MainActor func encryptionCoversTheWholePayload() throws {
        let (service, hosts, _, _, _) = try service()
        hosts.add(host("secret-project-bastion"))

        let document = try service.makeDocument(options: .init(includePrivateKeys: false, password: "correct horse"))
        #expect(document.isEncrypted)
        #expect(document.payload == nil, "the plain payload is not alongside the sealed one")

        // The list of servers someone connects to is worth protecting too.
        let text = String(decoding: try BackupService.encoder.encode(document), as: UTF8.self)
        #expect(!text.contains("secret-project-bastion"))

        let payload = try service.payload(of: document, password: "correct horse")
        #expect(payload.hosts.first?.name == "secret-project-bastion")
    }

    @Test("Private keys cannot be exported without a password")
    @MainActor func privateKeysNeedAPassword() throws {
        let (service, _, _, _, _) = try service()
        #expect(throws: BackupError.self) {
            _ = try service.makeDocument(options: .init(includePrivateKeys: true, password: ""))
        }
    }

    @Test("A key held behind Face ID is named as unexportable rather than silently skipped")
    @MainActor func biometricKeysAreDeclared() throws {
        let (service, hosts, _, _, _) = try service()
        hosts.add(StoredKey(
            id: UUID(), name: "phone-only", algorithm: "ssh-ed25519",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", fingerprintSHA256: "SHA256:x",
            createdAt: Date(), requiresBiometrics: true, isPassphraseProtected: false
        ))
        let unexportable = service.unexportableKeys()
        #expect(unexportable.count == 1)
        #expect(unexportable.first?.name == "phone-only")
        #expect(unexportable.first?.reason.contains("cannot leave this device") == true)
    }

    // MARK: - When it goes wrong

    @Test("A wrong password is reported as one, not as a broken file")
    @MainActor func wrongPassword() throws {
        let (service, hosts, _, _, _) = try service()
        hosts.add(host("build"))
        let document = try service.makeDocument(options: .init(password: "right"))
        #expect(throws: BackupError.wrongPassword) {
            _ = try service.payload(of: document, password: "wrong")
        }
        #expect(throws: BackupError.needsPassword) {
            _ = try service.payload(of: document, password: nil)
        }
    }

    @Test("A truncated or unrelated file is refused before anything is touched")
    @MainActor func damagedFiles() throws {
        let (service, _, _, _, _) = try service()
        #expect(throws: BackupError.notABackup) { _ = try service.read(Data("not json".utf8)) }
        #expect(throws: BackupError.notABackup) { _ = try service.read(Data("{}".utf8)) }

        // Well-formed, right shape, but carrying nothing — a file cut off mid-write.
        let empty = BackupDocument(formatVersion: 1, exportedAt: Date(), appVersion: "1", payload: nil, sealed: nil)
        let data = try BackupService.encoder.encode(empty)
        #expect(throws: BackupError.self) { _ = try service.read(data) }
    }

    @Test("A backup from a newer app says so instead of guessing")
    @MainActor func futureVersion() throws {
        let (service, _, _, _, _) = try service()
        var document = BackupDocument(
            formatVersion: BackupDocument.currentFormatVersion + 1,
            exportedAt: Date(), appVersion: "99", payload: .init(), sealed: nil
        )
        document.payload?.hosts = [host("x")]
        let data = try BackupService.encoder.encode(document)
        #expect(throws: BackupError.fromANewerVersion(BackupDocument.currentFormatVersion + 1)) {
            _ = try service.read(data)
        }
    }

    @Test("Tampering with a sealed backup is caught by the seal, not discovered later")
    @MainActor func tamperedCiphertext() throws {
        let (service, hosts, _, _, _) = try service()
        hosts.add(host("build"))
        var document = try service.makeDocument(options: .init(password: "pw"))
        var combined = document.sealed!.combined
        combined[combined.count - 1] ^= 0xFF
        document.sealed!.combined = combined
        #expect(throws: BackupError.wrongPassword) {
            _ = try service.payload(of: document, password: "pw")
        }
    }

    // MARK: - Settings

    @Test("Preferences worth carrying travel, and the file is byte-stable")
    @MainActor func settingsAndDeterminism() throws {
        let (service, _, _, _, settings) = try service()
        settings.fontSize = 15
        settings.scrollbackLimit = 4000
        settings.cursorBlink = false

        let first = try BackupService.encoder.encode(try service.makeDocument(options: .init()))
        let payload = try service.payload(of: try service.read(first), password: nil)
        #expect(payload.settings.fontSize == 15)
        #expect(payload.settings.scrollbackLimit == 4000)
        #expect(payload.settings.cursorBlink == false)

        // Two exports of the same state differ only in the timestamp, so a backup is
        // diffable and a person can see what actually changed between two of them.
        let second = try BackupService.encoder.encode(try service.makeDocument(options: .init()))
        func withoutTimestamp(_ data: Data) -> String {
            String(decoding: data, as: UTF8.self)
                .split(separator: "\n").filter { !$0.contains("exportedAt") }.joined(separator: "\n")
        }
        #expect(withoutTimestamp(first) == withoutTimestamp(second))
    }
}
