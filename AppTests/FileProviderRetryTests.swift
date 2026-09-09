import FileProvider
import Foundation
import NIOTransportServices
import STCore
import STFileProvider
import STSecureStore
import STSSH
import Testing

@testable import ApexTerminal

/// What happens when the connection dies in the middle of a transfer (D-044).
///
/// The File Provider is asked to move bytes at moments nobody chose: the system launches
/// the extension when Files needs it, on whatever network the device happens to have. A
/// connection found dead is ordinary, not exceptional, so it costs one retry — and a retry
/// is only safe if the second attempt starts from the beginning of the file, under a name
/// the first attempt is not still holding, having cleaned up what the first left behind.
///
/// This severs a real TCP connection during a real upload to prove it.
@Suite(
    "File Provider transfers survive a dropped connection",
    .enabled(if: AppIntegrationEnvironment.current != nil, "run scripts/app-integration-e2e.sh"),
    .serialized
)
@MainActor
struct FileProviderRetryTests {
    @Test("An upload cut in half finishes whole, once, with nothing left behind", .timeLimit(.minutes(2)))
    func severedUploadRecovers() async throws {
        let environment = try #require(AppIntegrationEnvironment.current)
        let proxy = SeverableTCPProxy(originHost: environment.host, originPort: environment.port)
        try await proxy.start()
        defer { Task { await proxy.shutdown() } }

        let knownHosts = InMemoryKnownHostsStore()
        let identity = KnownHostIdentity(host: "127.0.0.1", port: proxy.port)
        // The app approves the key first, exactly as a person would; the extension will
        // not connect to a host nobody has approved.
        let approval = try await SSHConnection.connect(
            transport: DirectTCPTransport(endpoint: TransportEndpoint(host: "127.0.0.1", port: proxy.port)),
            configuration: SSHConnectionConfiguration(
                username: environment.username,
                credentials: [.privateKey(try OpenSSHPrivateKeyParser.parse(pem: environment.privateKeyPEM))],
                knownHostIdentity: identity
            ),
            hostKeyVerifier: HostKeyVerifier(identity: identity, store: knownHosts, approval: TrustOnFirstUseApproval()),
            eventLoop: NIOTSEventLoopGroup.singleton.next()
        )
        await approval.close()

        let keyID = UUID()
        let store = TestKeyStore()
        try store.set(
            Data(environment.privateKeyPEM.utf8),
            for: SecureStoreKey(service: SecureStoreServices.privateKeys, account: keyID.uuidString),
            protection: .whenUnlockedThisDeviceOnly,
            prompt: nil
        )

        let root = NSTemporaryDirectory() + "apex-fp-retry-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let domain = SharedDomain(
            id: UUID(), displayName: "Severable", hostname: "127.0.0.1", port: proxy.port,
            username: environment.username, transport: .directTCP,
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
        defer { Task { await fileSystem.shutdown() } }

        // Big enough that the upload is still running seconds after it starts — over
        // loopback a small file is gone before a cut could land — and distinctive enough
        // that a partial or repeated write cannot pass as correct.
        let payload = Data((0 ..< 24_000_000).map { UInt8(($0 &* 31 &+ 7) % 251) })
        let source = URL(fileURLWithPath: NSTemporaryDirectory() + "severed-\(UUID().uuidString)")
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let progress = Progress(totalUnitCount: 0)
        // Watched rather than sampled. The restart is visible as `completedUnitCount`
        // going back to zero, and over loopback the upload passes the point it was cut at
        // within a few milliseconds — polling misses it often enough to make the test
        // lie about what it proved.
        let restarts = RestartRecorder(progress)
        let cut = Task { () -> Int64 in
            while progress.completedUnitCount == 0 {
                if Task.isCancelled { return -1 }
                try? await Task.sleep(for: .milliseconds(2))
            }
            let atCut = progress.completedUnitCount
            proxy.sever()
            return atCut
        }

        let item = try await fileSystem.write(
            contents: source,
            to: root + "/severed.bin",
            permissions: 0o600,
            progress: progress
        )
        let severedAt = await cut.value
        #expect(severedAt > 0, "the transfer never started, so nothing was cut")
        #expect(
            restarts.count >= 1,
            "the upload was never cut and restarted: severed at \(severedAt) of \(payload.count)"
        )

        #expect(item.documentSize?.intValue == payload.count)
        // The bytes on the server's own disk, read without the client.
        #expect(try Data(contentsOf: URL(fileURLWithPath: root + "/severed.bin")) == payload)
        // And no half-written upload left with a name nobody will ever clean up.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root)
        #expect(remaining == ["severed.bin"], "the severed attempt left something behind: \(remaining)")
    }
}

/// Counts the times an upload started over.
///
/// The retry resets `completedUnitCount` to zero before writing the first chunk again, so
/// a transition back to zero after the transfer has begun is exactly one restart.
private final class RestartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var restarts = 0
    private var observation: NSKeyValueObservation?

    init(_ progress: Progress) {
        observation = progress.observe(\.completedUnitCount, options: [.new]) { [weak self] _, change in
            guard let self, let value = change.newValue else { return }
            lock.withLock {
                if value > 0 { started = true } else if started { restarts += 1; started = false }
            }
        }
    }

    var count: Int { lock.withLock { restarts } }
}

/// A Keychain stand-in for this test, so it never touches the device's real one.
private final class TestKeyStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SecureStoreKey: Data] = [:]

    func set(_ data: Data, for key: SecureStoreKey, protection: SecureStoreProtection, prompt: String?) throws {
        lock.withLock { items[key] = data }
    }

    func get(_ key: SecureStoreKey, prompt: String?) throws -> Data {
        try lock.withLock {
            guard let data = items[key] else { throw SecureStoreError.itemNotFound }
            return data
        }
    }

    func remove(_ key: SecureStoreKey) throws { lock.withLock { _ = items.removeValue(forKey: key) } }

    func accounts(inService service: String) throws -> [String] {
        lock.withLock { items.keys.filter { $0.service == service }.map(\.account).sorted() }
    }

    func removeAll(inService service: String) throws {
        lock.withLock { for key in items.keys where key.service == service { items.removeValue(forKey: key) } }
    }
}
