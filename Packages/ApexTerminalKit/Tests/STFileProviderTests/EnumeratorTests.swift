import FileProvider
import Foundation
import NIOTransportServices
import STCore
import STSecureStore
import STSSH
import STTestSupport
import Testing

@testable import STFileProvider

/// The enumerator, against a real server (D-044).
///
/// What is being proved here is that "what changed" is a real answer. SFTP cannot push
/// changes, so the enumerator lists the folder again and compares — and the way to show
/// that works is to change the folder behind its back, with no involvement from the
/// provider at all, and then ask.
@Suite("File Provider enumeration", .serialized)
struct EnumeratorTests {
    private func withFileSystem(
        _ body: (DomainFileSystem, String) async throws -> Void
    ) async throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }

        let knownHosts = InMemoryKnownHostsStore()
        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
        let approval = try await SSHConnection.connect(
            transport: DirectTCPTransport(endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)),
            configuration: SSHConnectionConfiguration(
                username: server.fixtures.username,
                credentials: [.privateKey(try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM))],
                knownHostIdentity: identity
            ),
            hostKeyVerifier: HostKeyVerifier(identity: identity, store: knownHosts, approval: TrustOnFirstUseApproval()),
            eventLoop: NIOTSEventLoopGroup.singleton.next()
        )
        await approval.close()

        let keyID = UUID()
        let store = TestSecureStore()
        try store.set(
            Data(server.fixtures.clientPrivateKeyPEM.utf8),
            for: SecureStoreKey(service: SecureStoreServices.privateKeys, account: keyID.uuidString),
            protection: .whenUnlockedThisDeviceOnly,
            prompt: nil
        )

        let root = NSTemporaryDirectory() + "apex-fp-enum-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let domain = SharedDomain(
            id: UUID(), displayName: "Harness", hostname: "127.0.0.1", port: server.fixtures.port,
            username: server.fixtures.username, transport: .directTCP,
            credentials: [.privateKey(id: keyID)], rootPath: root
        )
        let fileSystem = DomainFileSystem(
            domain: domain,
            connection: DomainConnection(
                domain: domain, secureStore: store, knownHosts: knownHosts,
                group: NIOTSEventLoopGroup.singleton, userAgent: "ApexTerminalTests/1 (iOS)"
            ),
            identity: ItemIdentityMap(url: URL(fileURLWithPath: NSTemporaryDirectory() + "id-\(UUID().uuidString).json"))
        )
        do {
            try await body(fileSystem, root)
            await fileSystem.shutdown()
        } catch {
            await fileSystem.shutdown()
            throw error
        }
    }

    @Test("Enumerating a folder reports every item in it")
    func enumeratesEverything() async throws {
        try await withFileSystem { fileSystem, root in
            for index in 0 ..< 5 {
                try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/file\(index).txt"))
            }
            let enumerator = SFTPEnumerator(container: .rootContainer, fileSystem: fileSystem)
            let observer = RecordingEnumerationObserver()
            enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
            let items = try await observer.result()
            #expect(Set(items.map(\.filename)) == Set((0 ..< 5).map { "file\($0).txt" }))
        }
    }

    @Test("A change made on the server, with the provider uninvolved, is reported")
    func reportsRealChanges() async throws {
        try await withFileSystem { fileSystem, root in
            try Data("first".utf8).write(to: URL(fileURLWithPath: root + "/stays.txt"))
            try Data("doomed".utf8).write(to: URL(fileURLWithPath: root + "/goes.txt"))

            let enumerator = SFTPEnumerator(container: .rootContainer, fileSystem: fileSystem)
            let first = RecordingEnumerationObserver()
            enumerator.enumerateItems(for: first, startingAt: NSFileProviderPage(Data()))
            let before = try await first.result()
            #expect(before.count == 2)
            let doomed = try #require(before.first { $0.filename == "goes.txt" }).itemIdentifier

            let anchor = try #require(await currentAnchor(of: enumerator))

            // Someone else edits the server. Nothing here is told.
            try FileManager.default.removeItem(atPath: root + "/goes.txt")
            try Data("brand new".utf8).write(to: URL(fileURLWithPath: root + "/arrived.txt"))

            let changes = RecordingChangeObserver()
            enumerator.enumerateChanges(for: changes, from: anchor)
            let result = try await changes.result()
            #expect(result.updated.map(\.filename) == ["arrived.txt"])
            #expect(result.deleted == [doomed])
            #expect(result.anchor != anchor, "the anchor has to move on, or the next question repeats this answer")
        }
    }

    @Test("An anchor from an enumeration this process never did is expired, not answered")
    func staleAnchorExpires() async throws {
        try await withFileSystem { fileSystem, _ in
            let enumerator = SFTPEnumerator(container: .rootContainer, fileSystem: fileSystem)
            let changes = RecordingChangeObserver()
            enumerator.enumerateChanges(for: changes, from: NSFileProviderSyncAnchor(Data("from another life".utf8)))

            var caught: Error?
            do { _ = try await changes.result() } catch { caught = error }
            let error = try #require(caught as NSError?)
            #expect(error.domain == NSFileProviderErrorDomain)
            #expect(error.code == NSFileProviderError.syncAnchorExpired.rawValue)
        }
    }

    @Test("A folder that cannot be listed fails the enumeration instead of looking empty")
    func failureIsNotAnEmptyFolder() async throws {
        try await withFileSystem { fileSystem, root in
            try FileManager.default.createDirectory(atPath: root + "/locked", withIntermediateDirectories: false)
            let listed = try await fileSystem.contents(of: .rootContainer)
            let folder = try #require(listed.first { $0.filename == "locked" })
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/locked")
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root + "/locked") }

            let enumerator = SFTPEnumerator(container: folder.itemIdentifier, fileSystem: fileSystem)
            let observer = RecordingEnumerationObserver()
            enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))

            var caught: Error?
            do { _ = try await observer.result() } catch { caught = error }
            // An empty listing here would tell the user their files are gone.
            #expect(caught != nil, "a refused listing must not be reported as an empty folder")
        }
    }

    @Test("The working set is empty rather than pretending to be fresh")
    func workingSetIsEmpty() async throws {
        let enumerator = EmptyWorkingSetEnumerator()
        let observer = RecordingEnumerationObserver()
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
        #expect(try await observer.result().isEmpty)
    }

    private func currentAnchor(of enumerator: SFTPEnumerator) async -> NSFileProviderSyncAnchor? {
        await withCheckedContinuation { continuation in
            enumerator.currentSyncAnchor { continuation.resume(returning: $0) }
        }
    }
}

// MARK: - Observers

/// Collects one enumeration, and lets a test await it.
private final class RecordingEnumerationObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SFTPItem] = []
    private var continuation: CheckedContinuation<[SFTPItem], Error>?
    private var outcome: Result<[SFTPItem], Error>?

    func didEnumerate(_ updatedItems: [any NSFileProviderItemProtocol]) {
        lock.withLock { items.append(contentsOf: updatedItems.compactMap { $0 as? SFTPItem }) }
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        finish(.success(lock.withLock { items }))
    }

    func finishEnumeratingWithError(_ error: any Error) {
        finish(.failure(error))
    }

    func result() async throws -> [SFTPItem] {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<[SFTPItem], Error>? = lock.withLock {
                if let outcome { return outcome }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    private func finish(_ result: Result<[SFTPItem], Error>) {
        let waiting: CheckedContinuation<[SFTPItem], Error>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
}

private final class RecordingChangeObserver: NSObject, NSFileProviderChangeObserver, @unchecked Sendable {
    struct Result_: Sendable {
        var updated: [SFTPItem]
        var deleted: [NSFileProviderItemIdentifier]
        var anchor: NSFileProviderSyncAnchor
    }

    private let lock = NSLock()
    private var updated: [SFTPItem] = []
    private var deleted: [NSFileProviderItemIdentifier] = []
    private var continuation: CheckedContinuation<Result_, Error>?
    private var outcome: Result<Result_, Error>?

    func didUpdate(_ updatedItems: [any NSFileProviderItemProtocol]) {
        lock.withLock { updated.append(contentsOf: updatedItems.compactMap { $0 as? SFTPItem }) }
    }

    func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) {
        lock.withLock { deleted.append(contentsOf: deletedItemIdentifiers) }
    }

    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        let snapshot = lock.withLock { Result_(updated: updated, deleted: deleted, anchor: anchor) }
        finish(.success(snapshot))
    }

    func finishEnumeratingWithError(_ error: any Error) {
        finish(.failure(error))
    }

    func result() async throws -> Result_ {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<Result_, Error>? = lock.withLock {
                if let outcome { return outcome }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    private func finish(_ result: Result<Result_, Error>) {
        let waiting: CheckedContinuation<Result_, Error>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
}
