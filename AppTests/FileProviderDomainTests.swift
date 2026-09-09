// The File Provider extension does not exist on Mac Catalyst — the replicated API is
// unavailable there — so neither do its tests. See `FileProviderDomains.isAvailable`, which is
// what the app shows a Mac user instead (D-070).
#if !targetEnvironment(macCatalyst)
import FileProvider
import Foundation
import STCore
import STFileProvider
import STSSH
import Testing

@testable import ApexTerminal

/// Whether these tests are running in the simulator, which changes what the File Provider
/// can do — see the note on `isReplicated` below, and the end-to-end suite.
let runsInSimulator: Bool = {
    #if targetEnvironment(simulator)
    true
    #else
    false
    #endif
}()

/// The app half of the Files integration (D-044).
///
/// These run in the app host, so the entitlements are the real ones: if the App Group
/// were missing from the built app, the first test here would fail rather than the
/// feature quietly doing nothing on a device.
@Suite("File Provider domains", .serialized)
@MainActor
struct FileProviderDomainTests {
    private func makeContainer() -> (AppContainer, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory() + "fp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (AppContainer.testInstance(directory: directory), directory)
    }

    @Test("The shared App Group container really exists in this build")
    func appGroupIsEntitled() throws {
        // The entitlement is the feature: without it the extension cannot read anything
        // the app writes, and every folder in Files would be empty for a reason no log
        // would explain.
        let container = try #require(
            SharedContainer.url(),
            "the app is not entitled to \(SharedContainer.appGroup); the Files feature cannot work"
        )
        #expect(FileManager.default.fileExists(atPath: container.path))
    }

    @Test("A connection with no user name cannot be published")
    func usernameIsRequired() async {
        let (app, _) = makeContainer()
        let host = Host(name: "No user", hostname: "example.test", username: "")
        app.hostStore.add(host)
        #expect(await app.files.publishability(of: host) == .needsUsername)
    }

    @Test("A connection whose host key was never approved cannot be published")
    func hostKeyMustBeApproved() async throws {
        let (app, _) = makeContainer()
        let key = StoredKey(
            name: "k", algorithm: "ssh-ed25519", publicKeyOpenSSH: "ssh-ed25519 AAAA",
            fingerprintSHA256: "SHA256:x", requiresBiometrics: false, isPassphraseProtected: false
        )
        app.hostStore.add(key)
        let host = Host(
            name: "Unapproved", hostname: "example.test", username: "root",
            credentials: [.privateKey(id: key.id)]
        )
        app.hostStore.add(host)
        // No secret and no approval: the reason reported is the first one that applies,
        // and the host key is checked before credentials because it is the more serious.
        #expect(await app.files.publishability(of: host) == .hostKeyNotApproved)
    }

    @Test("A key behind Face ID is not a credential the extension can use")
    func biometricKeyIsNotUsable() async throws {
        let (app, _) = makeContainer()
        let identity = KnownHostIdentity(host: "example.test", port: 22)
        try await app.knownHosts.store(KnownHostEntry(
            identity: identity,
            key: SSHHostKey(algorithm: "ssh-ed25519", blob: Data([1, 2, 3])),
            firstSeen: Date(), lastSeen: Date()
        ))
        let key = StoredKey(
            name: "protected", algorithm: "ssh-ed25519", publicKeyOpenSSH: "ssh-ed25519 AAAA",
            fingerprintSHA256: "SHA256:y", requiresBiometrics: true, isPassphraseProtected: false
        )
        app.hostStore.add(key)
        let host = Host(
            name: "Face ID", hostname: "example.test", username: "root",
            credentials: [.privateKey(id: key.id)]
        )
        app.hostStore.add(host)
        #expect(await app.files.publishability(of: host) == .needsInteractiveCredential)
    }

    @Test("An enclave key that needs the device unlocked is a credential the extension can use")
    func unattendedEnclaveKeyIsUsable() async throws {
        try #require(SecureEnclaveSSHKey.isAvailable, "this device has no Secure Enclave")
        let (app, _) = makeContainer()
        let identity = KnownHostIdentity(host: "enclave.test", port: 22)
        try await app.knownHosts.store(KnownHostEntry(
            identity: identity,
            key: SSHHostKey(algorithm: "ssh-ed25519", blob: Data([4, 5, 6])),
            firstSeen: Date(), lastSeen: Date()
        ))
        let handle = try SecureEnclaveSSHKey.generate(accessPolicy: .deviceUnlocked, comment: "files")
        let key = StoredKey(
            name: "enclave", algorithm: handle.publicKey.algorithm,
            publicKeyOpenSSH: handle.publicKeyOpenSSH, fingerprintSHA256: handle.fingerprintSHA256,
            requiresBiometrics: false, isPassphraseProtected: false, isSecureEnclave: true
        )
        try app.vault.storeSecureEnclaveKey(handle.blob, id: key.id)
        defer { try? app.vault.deleteSecureEnclaveKey(id: key.id) }
        app.hostStore.add(key)
        let host = Host(
            name: "Enclave", hostname: "enclave.test", username: "root",
            credentials: [.privateKey(id: key.id)]
        )
        app.hostStore.add(host)

        // The enclave signs without anyone present, so this belongs in Files — and the
        // published record must name the enclave, not the ordinary key store, or the
        // extension would look for material that does not exist.
        #expect(await app.files.publishability(of: host) == .publishable)
        #expect(app.files.publishedCredentials(of: host) == [.secureEnclaveKey(id: key.id)])
    }

    @Test("An enclave key that asks for Face ID at every signature is not")
    func biometricEnclaveKeyIsNotUsable() async throws {
        let (app, _) = makeContainer()
        let identity = KnownHostIdentity(host: "enclave-bio.test", port: 22)
        try await app.knownHosts.store(KnownHostEntry(
            identity: identity,
            key: SSHHostKey(algorithm: "ssh-ed25519", blob: Data([7, 8, 9])),
            firstSeen: Date(), lastSeen: Date()
        ))
        // No enclave call: what is being checked is the app's rule, which must hold on a
        // device with no enclave at all.
        let key = StoredKey(
            name: "enclave-bio", algorithm: "ecdsa-sha2-nistp256",
            publicKeyOpenSSH: "ecdsa-sha2-nistp256 AAAA", fingerprintSHA256: "SHA256:bio",
            requiresBiometrics: true, isPassphraseProtected: false, isSecureEnclave: true
        )
        app.hostStore.add(key)
        let host = Host(
            name: "Enclave Face ID", hostname: "enclave-bio.test", username: "root",
            credentials: [.privateKey(id: key.id)]
        )
        app.hostStore.add(host)
        #expect(await app.files.publishability(of: host) == .needsInteractiveCredential)
    }

    @Test("Publishing a connection registers a domain and writes a record the extension can read")
    func publishRegistersADomain() async throws {
        let (app, _) = makeContainer()
        let identity = KnownHostIdentity(host: "files.test", port: 22)
        try await app.knownHosts.store(KnownHostEntry(
            identity: identity,
            key: SSHHostKey(algorithm: "ssh-ed25519", blob: Data([9, 9, 9])),
            firstSeen: Date(), lastSeen: Date()
        ))
        let host = Host(
            name: "Files harness \(UUID().uuidString.prefix(6))",
            hostname: "files.test", username: "root", credentials: [.password]
        )
        try app.vault.storePassword("not-a-real-password", hostID: host.id)
        defer { try? app.vault.deletePassword(hostID: host.id) }
        app.hostStore.add(host)

        #expect(await app.files.publishability(of: host) == .publishable)
        await app.files.setPublished(true, for: host)
        defer {
            Task {
                await app.files.setPublished(false, for: host)
            }
        }

        // The record the extension reads, in the container it reads it from.
        let store = try #require(SharedDomainStore.shared())
        let record = try #require(try store.domain(id: host.id))
        #expect(record.username == "root")
        #expect(record.credentials == [.storedPassword])
        #expect(record.transport == .directTCP)

        // And the domain the system knows about, which is what puts it in the sidebar.
        let domains = try await NSFileProviderManager.domains()
        let published = domains.first { $0.identifier.rawValue == host.id.uuidString }
        #expect(published != nil, "the domain was not registered; Files would show nothing")
        #expect(published?.displayName == host.name)
        // The domain is created as a replicated one, because the extension implements
        // only the replicated protocol. On a device it stays that way. The simulator has
        // no FPFS to back it, so `fileproviderd` logs "was asked with FPFS, but it's not
        // supported, will fallback" and quietly drops the flag — after which it tries to
        // serve the domain through the older API, finds no implementation, and aborts the
        // extension process. That is why the end-to-end suite runs on hardware only
        // (H-6). Asserting the downgrade rather than skipping the check keeps the day
        // this was diagnosed from having to be spent again.
        if #available(iOS 18.0, *) {
            #expect(published?.isReplicated == !runsInSimulator)
        }

        // Turning it off has to take it away again, or a deleted server haunts Files.
        await app.files.setPublished(false, for: host)
        let after = try await NSFileProviderManager.domains()
        #expect(!after.contains { $0.identifier.rawValue == host.id.uuidString })
        #expect(try store.domain(id: host.id) == nil)
    }

    @Test("Deleting a published connection withdraws its domain")
    func deletingWithdrawsTheDomain() async throws {
        let (app, _) = makeContainer()
        let identity = KnownHostIdentity(host: "gone.test", port: 22)
        try await app.knownHosts.store(KnownHostEntry(
            identity: identity,
            key: SSHHostKey(algorithm: "ssh-ed25519", blob: Data([4])),
            firstSeen: Date(), lastSeen: Date()
        ))
        var host = Host(name: "Doomed", hostname: "gone.test", username: "root", credentials: [.password])
        try app.vault.storePassword("x", hostID: host.id)
        defer { try? app.vault.deletePassword(hostID: host.id) }
        host.showsInFiles = true
        app.hostStore.add(host)
        await app.files.refresh()
        #expect(try #require(SharedDomainStore.shared()).domain(id: host.id) != nil)

        app.hostStore.remove(host)
        await app.files.refresh()
        let domains = try await NSFileProviderManager.domains()
        #expect(!domains.contains { $0.identifier.rawValue == host.id.uuidString })
        #expect(try #require(SharedDomainStore.shared()).domain(id: host.id) == nil)
    }

    @Test("Known host keys live where both processes can read them")
    func knownHostsAreShared() throws {
        let shared = try #require(SharedContainer.url())
        let directory = URL(fileURLWithPath: NSTemporaryDirectory() + "kh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The extension refuses any host it cannot find in this file, so the app writing
        // it somewhere else would mean nothing could ever be browsed.
        #expect(KnownHostsLocation.url(appContainer: directory) == SharedContainer.knownHostsURL(in: shared))
    }
}
#endif
