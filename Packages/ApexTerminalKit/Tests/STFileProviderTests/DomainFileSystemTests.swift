import FileProvider
import Foundation
import NIOTransportServices
import STCore
import STSecureStore
import STSFTP
import STSSH
import STTestSupport
import Testing

@testable import STFileProvider

/// The File Provider file system, driven against OpenSSH's own `internal-sftp` (D-044).
///
/// These are the tests that decide whether the feature works. The extension class itself
/// can only be exercised inside an extension host, so everything it does is in
/// ``DomainFileSystem`` — and this points that at a real server, does what Files would
/// do, and checks the real filesystem afterwards rather than asking the client whether it
/// thinks it succeeded.
@Suite("File Provider against real OpenSSH", .serialized)
struct DomainFileSystemTests {
    /// A server, a directory to work in, and a file system already allowed to connect.
    private func withFileSystem(
        _ body: (DomainFileSystem, String, OpenSSHTestServer) async throws -> Void
    ) async throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }
        let knownHosts = InMemoryKnownHostsStore()
        // The app connects first and records the host key, exactly as it does when the
        // user approves a fingerprint. Only then can the extension connect at all.
        try await approveHostKey(of: server, into: knownHosts)

        let keyID = UUID()
        let store = TestSecureStore()
        try store.set(
            Data(server.fixtures.clientPrivateKeyPEM.utf8),
            for: SecureStoreKey(service: SecureStoreServices.privateKeys, account: keyID.uuidString),
            protection: .whenUnlockedThisDeviceOnly,
            prompt: nil
        )

        let root = NSTemporaryDirectory() + "apex-fp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let fileSystem = makeFileSystem(
            server: server,
            root: root,
            credentials: [.privateKey(id: keyID)],
            store: store,
            knownHosts: knownHosts
        )
        do {
            try await body(fileSystem, root, server)
            await fileSystem.shutdown()
        } catch {
            await fileSystem.shutdown()
            throw error
        }
    }

    private func makeFileSystem(
        server: OpenSSHTestServer,
        root: String,
        credentials: [SharedDomain.Credential],
        store: any SecureStore,
        knownHosts: any KnownHostsStore
    ) -> DomainFileSystem {
        let domain = SharedDomain(
            id: UUID(),
            displayName: "Harness",
            hostname: "127.0.0.1",
            port: server.fixtures.port,
            username: server.fixtures.username,
            transport: .directTCP,
            credentials: credentials,
            rootPath: root
        )
        let connection = DomainConnection(
            domain: domain,
            secureStore: store,
            knownHosts: knownHosts,
            group: NIOTSEventLoopGroup.singleton,
            userAgent: "ApexTerminalTests/1 (iOS)"
        )
        return DomainFileSystem(
            domain: domain,
            connection: connection,
            identity: ItemIdentityMap(url: URL(fileURLWithPath: NSTemporaryDirectory() + "identity-\(UUID().uuidString).json"))
        )
    }

    private func approveHostKey(of server: OpenSSHTestServer, into store: any KnownHostsStore) async throws {
        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
        let connection = try await SSHConnection.connect(
            transport: DirectTCPTransport(endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)),
            configuration: SSHConnectionConfiguration(
                username: server.fixtures.username,
                credentials: [.privateKey(try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM))],
                knownHostIdentity: identity
            ),
            hostKeyVerifier: HostKeyVerifier(identity: identity, store: store, approval: TrustOnFirstUseApproval()),
            eventLoop: NIOTSEventLoopGroup.singleton.next()
        )
        await connection.close()
    }

    // MARK: - Security

    @Test("A host whose key was never approved is refused, not trusted on first use")
    func refusesUnknownHost() async throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }
        let keyID = UUID()
        let store = TestSecureStore()
        try store.set(
            Data(server.fixtures.clientPrivateKeyPEM.utf8),
            for: SecureStoreKey(service: SecureStoreServices.privateKeys, account: keyID.uuidString),
            protection: .whenUnlockedThisDeviceOnly,
            prompt: nil
        )
        // An empty known-hosts store is a host nobody has approved.
        let fileSystem = makeFileSystem(
            server: server,
            root: NSTemporaryDirectory(),
            credentials: [.privateKey(id: keyID)],
            store: store,
            knownHosts: InMemoryKnownHostsStore()
        )
        defer { Task { await fileSystem.shutdown() } }

        var caught: Error?
        do {
            _ = try await fileSystem.contents(of: .rootContainer)
        } catch {
            caught = error
        }
        let failure = try #require(caught as? STError)
        #expect(failure.category == .hostKey, "expected a host-key refusal, got \(failure)")

        // And the mapping the user actually meets: Files offers to sign in, in the app.
        let mapped = FileProviderErrorMapping.fileProviderError(from: failure) as NSError
        #expect(mapped.domain == NSFileProviderErrorDomain)
        #expect(mapped.code == NSFileProviderError.notAuthenticated.rawValue)
    }

    @Test("A key that needs Face ID is refused rather than prompted for in the background")
    func refusesInteractiveKey() async throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }
        let knownHosts = InMemoryKnownHostsStore()
        try await approveHostKey(of: server, into: knownHosts)

        let keyID = UUID()
        let store = TestSecureStore()
        try store.set(
            Data(server.fixtures.clientPrivateKeyPEM.utf8),
            for: SecureStoreKey(service: SecureStoreServices.privateKeys, account: keyID.uuidString),
            protection: .biometricThisDeviceOnly,
            prompt: nil
        )
        let fileSystem = makeFileSystem(
            server: server,
            root: NSTemporaryDirectory(),
            credentials: [.privateKey(id: keyID)],
            store: store,
            knownHosts: knownHosts
        )
        defer { Task { await fileSystem.shutdown() } }

        var caught: Error?
        do {
            _ = try await fileSystem.contents(of: .rootContainer)
        } catch {
            caught = error
        }
        #expect(caught is FileProviderFailure, "expected the app to be asked for, got \(String(describing: caught))")
    }

    // MARK: - Browsing and transfer

    @Test("The root enumerates what is really in the directory")
    func enumeratesRealDirectory() async throws {
        try await withFileSystem { fileSystem, root, _ in
            try Data("one".utf8).write(to: URL(fileURLWithPath: root + "/one.txt"))
            try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: false)

            let items = try await fileSystem.contents(of: .rootContainer)
            #expect(Set(items.map(\.filename)) == ["one.txt", "sub"])
            let folder = try #require(items.first { $0.filename == "sub" })
            #expect(folder.isDirectory)
            #expect(folder.contentType == .folder)
            let file = try #require(items.first { $0.filename == "one.txt" })
            #expect(file.documentSize?.intValue == 3)
            #expect(file.parentItemIdentifier == .rootContainer)
        }
    }

    @Test("A file uploaded through the provider is on the server's disk, byte for byte")
    func uploadLandsOnDisk() async throws {
        try await withFileSystem { fileSystem, root, _ in
            let payload = Data((0 ..< 200_000).map { UInt8($0 % 251) })
            let source = URL(fileURLWithPath: NSTemporaryDirectory() + "upload-\(UUID().uuidString)")
            try payload.write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }

            let progress = Progress(totalUnitCount: 0)
            let item = try await fileSystem.write(
                contents: source,
                to: root + "/big.bin",
                permissions: 0o600,
                progress: progress
            )
            #expect(item.filename == "big.bin")
            #expect(item.documentSize?.intValue == payload.count)
            #expect(progress.completedUnitCount == Int64(payload.count))

            // Read without the client: the bytes are in the real filesystem.
            #expect(try Data(contentsOf: URL(fileURLWithPath: root + "/big.bin")) == payload)
            // And nothing was left behind by the commit-by-rename.
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: root)
            #expect(leftovers == ["big.bin"], "temporary upload files were left behind: \(leftovers)")
        }
    }

    @Test("Downloading returns the file's real bytes and reports progress")
    func downloadMatches() async throws {
        try await withFileSystem { fileSystem, root, _ in
            let payload = Data((0 ..< 150_000).map { UInt8(($0 &* 7) % 253) })
            try payload.write(to: URL(fileURLWithPath: root + "/download.bin"))

            let items = try await fileSystem.contents(of: .rootContainer)
            let item = try #require(items.first { $0.filename == "download.bin" })
            let destination = URL(fileURLWithPath: NSTemporaryDirectory() + "dl-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: destination) }

            let progress = Progress(totalUnitCount: 0)
            let fetched = try await fileSystem.fetchContents(of: item.itemIdentifier, to: destination, progress: progress)
            #expect(try Data(contentsOf: destination) == payload)
            #expect(fetched.documentSize?.intValue == payload.count)
            #expect(progress.completedUnitCount == Int64(payload.count))
        }
    }

    @Test("Overwriting an existing file replaces it and leaves no temporary behind")
    func overwriteReplaces() async throws {
        try await withFileSystem { fileSystem, root, _ in
            try Data("old".utf8).write(to: URL(fileURLWithPath: root + "/note.txt"))
            let source = URL(fileURLWithPath: NSTemporaryDirectory() + "new-\(UUID().uuidString)")
            try Data("brand new contents".utf8).write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }

            _ = try await fileSystem.write(
                contents: source,
                to: root + "/note.txt",
                permissions: nil,
                progress: Progress(totalUnitCount: 0)
            )
            #expect(try String(contentsOf: URL(fileURLWithPath: root + "/note.txt"), encoding: .utf8) == "brand new contents")
            let remaining = try FileManager.default.contentsOfDirectory(atPath: root)
            #expect(remaining == ["note.txt"], "unexpected leftovers: \(remaining)")
        }
    }

    @Test("A new folder is created on the server")
    func createsFolder() async throws {
        try await withFileSystem { fileSystem, root, _ in
            let item = try await fileSystem.createDirectory(named: "Reports", in: .rootContainer)
            #expect(item.isDirectory)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: root + "/Reports", isDirectory: &isDirectory)
            #expect(exists)
            #expect(isDirectory.boolValue)
        }
    }

    @Test("Deleting removes the file, and a folder, from the server")
    func deletesBoth() async throws {
        try await withFileSystem { fileSystem, root, _ in
            try Data("bye".utf8).write(to: URL(fileURLWithPath: root + "/gone.txt"))
            try FileManager.default.createDirectory(atPath: root + "/empty", withIntermediateDirectories: false)

            let items = try await fileSystem.contents(of: .rootContainer)
            for item in items {
                try await fileSystem.delete(item.itemIdentifier)
            }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: root)
            #expect(remaining.isEmpty, "still there: \(remaining)")
        }
    }

    // MARK: - Identity

    @Test("A rename keeps the item's identifier, so the system does not lose the file")
    func renameKeepsIdentity() async throws {
        try await withFileSystem { fileSystem, root, _ in
            try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/before.txt"))
            let before = try #require(try await fileSystem.contents(of: .rootContainer).first)

            let after = try await fileSystem.move(before.itemIdentifier, toParent: nil, newName: "after.txt")
            #expect(after.itemIdentifier == before.itemIdentifier)
            #expect(after.filename == "after.txt")
            #expect(FileManager.default.fileExists(atPath: root + "/after.txt"))

            // And the identifier still resolves, which is what `item(for:)` needs.
            let refetched = try await fileSystem.item(for: before.itemIdentifier)
            #expect(refetched.filename == "after.txt")
        }
    }

    @Test("Moving a folder carries its children's identifiers with it")
    func moveCarriesChildren() async throws {
        try await withFileSystem { fileSystem, root, _ in
            try FileManager.default.createDirectory(atPath: root + "/box", withIntermediateDirectories: false)
            try Data("in".utf8).write(to: URL(fileURLWithPath: root + "/box/inside.txt"))
            try FileManager.default.createDirectory(atPath: root + "/target", withIntermediateDirectories: false)

            let box = try #require(try await fileSystem.contents(of: .rootContainer).first { $0.filename == "box" })
            let child = try #require(try await fileSystem.contents(of: box.itemIdentifier).first)
            let target = try #require(try await fileSystem.contents(of: .rootContainer).first { $0.filename == "target" })

            _ = try await fileSystem.move(box.itemIdentifier, toParent: target.itemIdentifier, newName: nil)
            #expect(FileManager.default.fileExists(atPath: root + "/target/box/inside.txt"))

            // The child was never mentioned in the move, but it moved with its folder —
            // and the system can still find it by the identifier it already had.
            let movedChild = try await fileSystem.item(for: child.itemIdentifier)
            #expect(movedChild.path == root + "/target/box/inside.txt")
        }
    }

    @Test("An identifier this device has never seen is reported as no such item")
    func unknownIdentifier() async throws {
        try await withFileSystem { fileSystem, _, _ in
            var caught: Error?
            do {
                _ = try await fileSystem.item(for: NSFileProviderItemIdentifier("never-enumerated"))
            } catch {
                caught = error
            }
            let error = try #require(caught as NSError?)
            #expect(error.domain == NSFileProviderErrorDomain)
            #expect(error.code == NSFileProviderError.noSuchItem.rawValue)
        }
    }

    @Test("A symbolic link to a folder is shown as a folder Files can open")
    func resolvesSymbolicLinks() async throws {
        try await withFileSystem { fileSystem, root, _ in
            try FileManager.default.createDirectory(atPath: root + "/real", withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/real")

            let items = try await fileSystem.contents(of: .rootContainer)
            let link = try #require(items.first { $0.filename == "link" })
            #expect(link.isDirectory, "a link to a directory has to be enterable, or the folder is unreachable")
            #expect(link.capabilities.contains(.allowsContentEnumerating))
        }
    }

    // MARK: - Errors

    @Test("A file the server refuses to read maps to a permission error, not a sign-in prompt")
    func permissionDeniedIsNotASignInLoop() async throws {
        try await withFileSystem { fileSystem, root, _ in
            let path = root + "/secret.txt"
            try Data("shh".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }

            let item = try #require(try await fileSystem.contents(of: .rootContainer).first)
            var caught: Error?
            do {
                _ = try await fileSystem.fetchContents(
                    of: item.itemIdentifier,
                    to: URL(fileURLWithPath: NSTemporaryDirectory() + UUID().uuidString),
                    progress: Progress(totalUnitCount: 0)
                )
            } catch {
                caught = error
            }
            let sftp = try #require(caught as? SFTPError)
            #expect(sftp.status == .permissionDenied)
            let mapped = FileProviderErrorMapping.fileProviderError(from: sftp) as NSError
            #expect(mapped.domain == NSCocoaErrorDomain)
            #expect(mapped.code == NSFileWriteNoPermissionError)
        }
    }
}
