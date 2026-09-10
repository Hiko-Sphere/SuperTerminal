// The File Provider extension does not exist on Mac Catalyst — the replicated API is
// unavailable there — so neither do its tests. See `FileProviderDomains.isAvailable`, which is
// what the app shows a Mac user instead (D-070).
#if !targetEnvironment(macCatalyst)
import FileProvider
import Foundation
import NIOTransportServices
import STCore
import STFileProvider
import STSSH
import Testing

@testable import ApexTerminal

/// Files, end to end: the system's own file machinery, the extension in its own process,
/// and a real OpenSSH server (D-044).
///
/// Every other test in this feature drives one half. This drives none of it directly — it
/// publishes a domain, asks the system where that domain's root is, and then reads it with
/// `FileManager`, exactly as any app on the device would. If the extension were not
/// installed, not enabled, unable to read the shared container or unable to reach the
/// server, this would fail, and nothing here would say what went wrong. That is the point:
/// it is the only test that proves the whole path.
///
/// It needs the SSH server `scripts/app-integration-e2e.sh` starts, and a real device.
///
/// **What the simulator can and cannot show, measured rather than assumed.** This comment used
/// to say that the simulator has no FPFS, that the domain is therefore downgraded, that the
/// extension therefore aborts, and that nothing could be concluded from any of it. The first
/// clause was never checked and the rest followed from it. The downgrade had a cause the app
/// owned: `NSExtensionFileProviderSupportsEnumeration` was missing from the extension's
/// Info.plist, `fileproviderd` answers a missing key by refusing FPFS, and a domain it refuses
/// FPFS for is served through an API this extension does not implement — `abort()` (D-073).
///
/// With the key in place the domain stays `(disabled,replicated,…)` here, the "will fallback"
/// line is gone, and this suite runs instead of killing the extension. It then **times out
/// after 60 seconds waiting for the published folder to appear in the domain root**, which is
/// the real and much narrower thing the simulator does not do. H-6 is now for that.
@Suite(
    "Files app end to end",
    .enabled(if: AppIntegrationEnvironment.current != nil, "run scripts/app-integration-e2e.sh"),
    // Measured after D-073, not assumed: with the domain staying replicated the extension is
    // no longer aborted here, and this suite *runs* — it then times out after 60 seconds
    // waiting for the published folder to appear in the domain root. That is a smaller and
    // much more specific claim than the one this skip used to carry, and it is what H-6 is
    // now for.
    .enabled(if: !runsInSimulator, "the domain is replicated here, but the folder never appears in the domain root"),
    .serialized
)
@MainActor
struct FileProviderEndToEndTests {
    @Test("A published server can be browsed and read through the Files machinery", .timeLimit(.minutes(2)))
    func browsesThroughTheSystem() async throws {
        let environment = try #require(AppIntegrationEnvironment.current)
        let app = AppContainer.testInstance(
            directory: URL(fileURLWithPath: NSTemporaryDirectory() + "fp-e2e-\(UUID().uuidString)")
        )

        // What the user would see on the server. Created here, on the real filesystem the
        // server serves, with nothing in this app involved.
        let marker = "APEX_FILE_PROVIDER_E2E\n"
        let folderName = "apex-fp-e2e-\(UUID().uuidString.prefix(8))"
        let onDisk = URL(fileURLWithPath: NSHomeDirectoryForServer() + "/" + folderName)
        try FileManager.default.createDirectory(at: onDisk, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: onDisk) }
        try Data(marker.utf8).write(to: onDisk.appendingPathComponent("hello.txt"))

        // The app approves the host key first, as a person would, because the extension
        // refuses anything it has not seen approved.
        let keyID = UUID()
        try app.vault.storePrivateKey(environment.privateKeyPEM, id: keyID, requireBiometrics: false)
        defer { try? app.vault.deletePrivateKey(id: keyID) }
        try await approveHostKey(environment: environment, store: app.knownHosts)

        let key = StoredKey(
            id: keyID, name: "harness", algorithm: "ssh-ed25519",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", fingerprintSHA256: environment.hostKeyFingerprint,
            requiresBiometrics: false, isPassphraseProtected: false
        )
        app.hostStore.add(key)
        var host = Host(
            name: "E2E \(folderName)", hostname: environment.host, port: environment.port,
            username: environment.username, credentials: [.privateKey(id: keyID)]
        )
        host.showsInFiles = true
        app.hostStore.add(host)
        await app.files.refresh()
        defer { Task { await app.files.setPublished(false, for: host) } }

        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(host.id.uuidString),
            displayName: host.name
        )
        let manager = try #require(NSFileProviderManager(for: domain), "the domain was not registered")
        // The domain is not usable the instant it is added: the system has to start the
        // provider first, and asking too early is refused rather than delayed.
        let root = try await eventuallyAsync("the domain's root has a URL") {
            try? await manager.getUserVisibleURL(for: .rootContainer)
        }
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }

        // The listing comes from the extension, which had to connect, authenticate and
        // run READDIR to answer it.
        let names = try await eventually("the published folder appears in the domain root") {
            let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
            return contents.contains(folderName) ? contents : nil
        }
        #expect(names.contains(folderName))

        let folder = root.appendingPathComponent(folderName)
        let inside = try await eventually("the file inside it is listed") {
            let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            return contents.contains("hello.txt") ? contents : nil
        }
        #expect(inside == ["hello.txt"])

        // And the bytes: downloaded by the extension over SFTP, materialised by the
        // system, read back here as an ordinary file.
        let text = try await eventually("the file's contents are readable") {
            try? String(contentsOf: folder.appendingPathComponent("hello.txt"), encoding: .utf8)
        }
        #expect(text == marker)
    }

    /// The directory the harness server logs in to. The simulator shares the Mac's
    /// filesystem, so this is the same path on both sides of the connection.
    private func NSHomeDirectoryForServer() -> String {
        ProcessInfo.processInfo.environment["ST_APP_TEST_SSH_HOME"] ?? NSHomeDirectory()
    }

    private func approveHostKey(environment: AppIntegrationEnvironment, store: any KnownHostsStore) async throws {
        let identity = KnownHostIdentity(host: environment.host, port: environment.port)
        let connection = try await SSHConnection.connect(
            transport: DirectTCPTransport(endpoint: TransportEndpoint(host: environment.host, port: environment.port)),
            configuration: SSHConnectionConfiguration(
                username: environment.username,
                credentials: [.privateKey(try OpenSSHPrivateKeyParser.parse(pem: environment.privateKeyPEM))],
                knownHostIdentity: identity
            ),
            hostKeyVerifier: HostKeyVerifier(identity: identity, store: store, approval: TrustOnFirstUseApproval()),
            eventLoop: NIOTSEventLoopGroup.singleton.next()
        )
        await connection.close()
    }

    /// Polls until the system has caught up.
    ///
    /// The File Provider is asynchronous by design: the system launches the extension,
    /// asks it for an enumeration and updates its own database, and none of that is
    /// instant. Waiting is honest here; asserting on the first attempt would make a
    /// working feature look broken at random.
    private func eventually<T>(
        _ what: String,
        timeout: Duration = .seconds(60),
        _ body: () throws -> T?
    ) async throws -> T {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var lastError: Error?
        while ContinuousClock.now < deadline {
            do {
                if let value = try body() { return value }
                lastError = nil
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw EventuallyTimedOut(what: what, lastError: lastError)
    }

    /// The same, for something that has to be awaited rather than merely tried.
    private func eventuallyAsync<T>(
        _ what: String,
        timeout: Duration = .seconds(60),
        _ body: () async -> T?
    ) async throws -> T {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let value = await body() { return value }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw EventuallyTimedOut(what: what, lastError: nil)
    }

    private struct EventuallyTimedOut: Error, CustomStringConvertible {
        let what: String
        let lastError: Error?
        var description: String {
            "timed out waiting until \(what)" + (lastError.map { "; last error: \($0)" } ?? "")
        }
    }
}
#endif
