import FileProvider
import Foundation
import STCore
import STSFTP
import Testing

@testable import STFileProvider

@Suite("File Provider identity and publishing")
struct FileProviderUnitTests {
    private func temporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "apex-fp-unit-\(UUID().uuidString)")
    }

    @Test("An identifier survives the process that issued it")
    func identityPersists() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = ItemIdentityMap(url: url)
        let identifier = await first.identifier(forPath: "/home/user/report.txt")

        // A different instance, as after the system killed and relaunched the extension.
        let second = ItemIdentityMap(url: url)
        #expect(await second.path(for: identifier) == "/home/user/report.txt")
        #expect(await second.identifier(forPath: "/home/user/report.txt") == identifier)
    }

    @Test("Renaming a folder re-roots every identifier beneath it")
    func renameReRootsSubtree() async throws {
        let map = ItemIdentityMap(url: temporaryURL())
        let folder = await map.identifier(forPath: "/data/old")
        let child = await map.identifier(forPath: "/data/old/deep/file.txt")

        await map.move(from: "/data/old", to: "/data/new")

        #expect(await map.path(for: folder) == "/data/new")
        // Without re-rooting, this child would still claim to live in a folder that no
        // longer exists, and every later operation on it would hit the wrong path.
        #expect(await map.path(for: child) == "/data/new/deep/file.txt")
    }

    @Test("Deleting a folder forgets the identifiers beneath it")
    func deleteForgetsSubtree() async throws {
        let map = ItemIdentityMap(url: temporaryURL())
        let child = await map.identifier(forPath: "/data/box/inner.txt")
        await map.forget("/data/box")
        #expect(await map.path(for: child) == nil)
    }

    @Test("A moved-onto path does not keep the identifier of what it replaced")
    func moveOverwritesDestinationIdentity() async throws {
        let map = ItemIdentityMap(url: temporaryURL())
        let replaced = await map.identifier(forPath: "/data/target.txt")
        let source = await map.identifier(forPath: "/data/source.txt")

        await map.move(from: "/data/source.txt", to: "/data/target.txt")

        #expect(await map.path(for: source) == "/data/target.txt")
        #expect(await map.path(for: replaced) == nil, "the overwritten file's identifier must not survive")
    }

    @Test("A trailing slash does not create a second identity for one folder")
    func normalisesTrailingSlash() async throws {
        let map = ItemIdentityMap(url: temporaryURL())
        let plain = await map.identifier(forPath: "/var/log")
        #expect(await map.identifier(forPath: "/var/log/") == plain)
    }

    @Test("Published domains survive a round trip through the shared container")
    func domainStoreRoundTrip() throws {
        let directory = temporaryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedDomainStore(directory: directory)
        #expect(try store.load().isEmpty)

        let domain = SharedDomain(
            id: UUID(),
            displayName: "Build box",
            hostname: "build.example",
            port: 2222,
            username: "ci",
            transport: .cloudflare(jumpDestination: "inner:22"),
            credentials: [.storedPassword],
            rootPath: "/srv"
        )
        try store.save([domain])
        #expect(try store.load() == [domain])
        #expect(try store.domain(id: domain.id) == domain)
        #expect(try store.domain(id: UUID()) == nil)
    }

    @Test("The published record carries no secret")
    func recordHoldsNoSecret() throws {
        let domain = SharedDomain(
            id: UUID(),
            displayName: "Box",
            hostname: "box.example",
            port: 22,
            username: "root",
            transport: .directTCP,
            credentials: [.privateKey(id: UUID()), .storedPassword]
        )
        // The file lands in a shared container that every extension of this app can read,
        // so what it may contain is a security property, not a style preference.
        let json = String(decoding: try JSONEncoder().encode(domain), as: UTF8.self).lowercased()
        for forbidden in ["password\":\"", "secret", "-----begin", "clientsecret"] {
            #expect(!json.contains(forbidden), "the published record leaked \(forbidden): \(json)")
        }
    }

    @Test("The host-key identity matches the one the terminal already recorded")
    func identityMatchesTheTerminal() {
        let direct = SharedDomain(
            id: UUID(), displayName: "d", hostname: "Example.COM", port: 22,
            username: "u", transport: .directTCP, credentials: []
        )
        #expect(direct.knownHostIdentity.storageKey == "example.com:22")

        let tunnelled = SharedDomain(
            id: UUID(), displayName: "d", hostname: "ssh.example.com", port: 443,
            username: "u", transport: .cloudflare(jumpDestination: "Inner:22"), credentials: []
        )
        #expect(tunnelled.knownHostIdentity.storageKey == "ssh.example.com:443/inner:22")
    }

    @Test("Every SFTP failure maps to the error Files can act on")
    func errorMapping() {
        func mapped(_ error: Error) -> NSError {
            FileProviderErrorMapping.fileProviderError(from: error) as NSError
        }

        let missing = mapped(SFTPError.serverRefused(.noSuchFile, "no such file"))
        #expect(missing.domain == NSFileProviderErrorDomain)
        #expect(missing.code == NSFileProviderError.noSuchItem.rawValue)

        let dropped = mapped(SFTPError.channelClosed)
        #expect(dropped.code == NSFileProviderError.serverUnreachable.rawValue)

        let unreachable = mapped(STError(category: .network, message: "no route"))
        #expect(unreachable.code == NSFileProviderError.serverUnreachable.rawValue)

        let changedKey = mapped(STError(category: .hostKey, message: "the key changed"))
        #expect(changedKey.code == NSFileProviderError.notAuthenticated.rawValue)
        #expect(changedKey.localizedDescription == "the key changed")

        let needsApp = mapped(FileProviderFailure.needsTheApp(reason: "open the app"))
        #expect(needsApp.code == NSFileProviderError.notAuthenticated.rawValue)
        #expect(needsApp.localizedDescription == "open the app")

        let unsupported = mapped(SFTPError.serverRefused(.operationUnsupported, "nope"))
        #expect(unsupported.domain == NSCocoaErrorDomain)
        #expect(unsupported.code == NSFeatureUnsupportedError)
    }

    @Test("A file's capabilities allow what SFTP can really do, and nothing else")
    func capabilities() {
        let file = SFTPItem(
            identifier: NSFileProviderItemIdentifier("a"),
            parent: .rootContainer,
            filename: "notes.txt",
            path: "/notes.txt",
            attributes: SFTP.Attributes(size: 12, permissions: 0x8000 | 0o644)
        )
        #expect(file.capabilities.contains(.allowsWriting))
        #expect(file.capabilities.contains(.allowsReparenting))
        // No trash on a server: offering it would promise an undo that does not exist.
        #expect(!file.capabilities.contains(.allowsTrashing))
        #expect(file.contentType == .plainText)

        let folder = SFTPItem(
            identifier: NSFileProviderItemIdentifier("b"),
            parent: .rootContainer,
            filename: "docs",
            path: "/docs",
            attributes: SFTP.Attributes(permissions: 0x4000 | 0o755)
        )
        #expect(folder.capabilities.contains(.allowsAddingSubItems))
        #expect(folder.capabilities.contains(.allowsContentEnumerating))
        #expect(!folder.capabilities.contains(.allowsTrashing))
        #expect(folder.documentSize == nil, "a folder has no document size to report")
    }

    @Test("The item version changes when the file does, and only then")
    func versioning() {
        func item(size: UInt64, modified: Date, permissions: UInt32) -> SFTPItem {
            SFTPItem(
                identifier: NSFileProviderItemIdentifier("a"),
                parent: .rootContainer,
                filename: "f",
                path: "/f",
                attributes: SFTP.Attributes(size: size, permissions: permissions, modified: modified)
            )
        }
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let base = item(size: 10, modified: when, permissions: 0o644)
        #expect(base.itemVersion.contentVersion == item(size: 10, modified: when, permissions: 0o644).itemVersion.contentVersion)
        #expect(base.itemVersion.contentVersion != item(size: 11, modified: when, permissions: 0o644).itemVersion.contentVersion)
        #expect(base.itemVersion.contentVersion != item(size: 10, modified: when.addingTimeInterval(60), permissions: 0o644).itemVersion.contentVersion)
        #expect(base.itemVersion.metadataVersion != item(size: 10, modified: when, permissions: 0o600).itemVersion.metadataVersion)
    }
}
