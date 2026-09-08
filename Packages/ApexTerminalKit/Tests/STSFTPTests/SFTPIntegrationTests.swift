import Foundation
import NIOTransportServices
import STCore
import STSFTP
import STSSH
import STTestSupport
import Testing

/// SFTP against OpenSSH's own `internal-sftp` (D-041).
///
/// The point of running against the real server is that a hand-written one would agree
/// with whatever this client does. `internal-sftp` does not: it enforces the draft, it
/// pages directory listings its own way, and it refuses what a real server refuses.
@Suite("SFTP against real OpenSSH", .serialized)
struct SFTPIntegrationTests {
    private func withClient<T>(_ body: (SFTPClient, OpenSSHTestServer) async throws -> T) async throws -> T {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }
        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
        let connection = try await SSHConnection.connect(
            transport: DirectTCPTransport(
                endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)
            ),
            configuration: SSHConnectionConfiguration(
                username: server.fixtures.username,
                credentials: [.privateKey(try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM))],
                knownHostIdentity: identity
            ),
            hostKeyVerifier: HostKeyVerifier(
                identity: identity, store: InMemoryKnownHostsStore(), approval: TrustOnFirstUseApproval()
            ),
            eventLoop: NIOTSEventLoopGroup.singleton.next()
        )
        let client = try await connection.openSFTP()
        do {
            let result = try await body(client, server)
            await client.close()
            await connection.close()
            return result
        } catch {
            await client.close()
            await connection.close()
            throw error
        }
    }

    /// A scratch directory under the server's temporary root, so a failing test cannot
    /// leave anything in a real home directory.
    private func scratch(_ server: OpenSSHTestServer) -> String {
        NSTemporaryDirectory() + "apex-sftp-\(UUID().uuidString)"
    }

    @Test("The subsystem starts, agrees version 3, and resolves a path")
    func handshakeAndRealpath() async throws {
        try await withClient { client, _ in
            let home = try await client.realpath(".")
            #expect(home.hasPrefix("/"), "realpath returns an absolute path, got \(home)")
        }
    }

    @Test("A file written through SFTP is on disk, byte for byte, and lists correctly")
    func writeReadAndList() async throws {
        try await withClient { client, server in
            let directory = self.scratch(server)
            try await client.makeDirectory(directory, permissions: 0o700)

            let path = directory + "/hello.txt"
            let contents = Array("SFTP_E2E_OK\n".utf8)
            let handle = try await client.open(path, flags: [.write, .create, .truncate], permissions: 0o600)
            try await client.write(handle: handle, offset: 0, bytes: contents)
            try await client.closeHandle(handle)

            // The real proof: the bytes are in the real filesystem, put there by the real
            // server, and readable without going through this client at all.
            let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(Array(onDisk) == contents)

            let listing = try await client.listDirectory(directory)
            #expect(listing.count == 1)
            #expect(listing.first?.filename == "hello.txt")
            #expect(listing.first?.attributes.isRegularFile == true)
            #expect(listing.first?.attributes.size == UInt64(contents.count))

            // And back out through the protocol.
            let reading = try await client.open(path, flags: [.read])
            let read = try await client.read(handle: reading, offset: 0, length: SFTPClient.readChunk)
            #expect(read == contents)
            // A second read past the end is EOF, not an error and not an empty chunk.
            let past = try await client.read(handle: reading, offset: UInt64(contents.count), length: 1024)
            #expect(past == nil)
            try await client.closeHandle(reading)

            try await client.remove(path)
            try await client.removeDirectory(directory)
        }
    }

    @Test("A file larger than one chunk survives the round trip")
    func multipleChunks() async throws {
        try await withClient { client, server in
            let directory = self.scratch(server)
            try await client.makeDirectory(directory, permissions: 0o700)
            let path = directory + "/big.bin"

            // Deliberately not a multiple of the chunk size, so the last write and the
            // last read are both partial — where an off-by-one lives.
            var payload = [UInt8]()
            payload.reserveCapacity(100_000)
            for index in 0 ..< 100_000 { payload.append(UInt8(truncatingIfNeeded: index &* 31)) }

            let handle = try await client.open(path, flags: [.write, .create, .truncate], permissions: 0o600)
            var offset = 0
            while offset < payload.count {
                let end = min(offset + SFTPClient.readChunk, payload.count)
                try await client.write(handle: handle, offset: UInt64(offset), bytes: Array(payload[offset ..< end]))
                offset = end
            }
            try await client.closeHandle(handle)

            let reading = try await client.open(path, flags: [.read])
            var received = [UInt8]()
            var at: UInt64 = 0
            while let chunk = try await client.read(handle: reading, offset: at, length: SFTPClient.readChunk) {
                received.append(contentsOf: chunk)
                at += UInt64(chunk.count)
            }
            try await client.closeHandle(reading)

            #expect(received.count == payload.count)
            #expect(received == payload, "every byte, in order")

            try await client.remove(path)
            try await client.removeDirectory(directory)
        }
    }

    @Test("A listing pages through more entries than one READDIR returns")
    func largeListingPages() async throws {
        try await withClient { client, server in
            let directory = self.scratch(server)
            try await client.makeDirectory(directory, permissions: 0o700)
            // OpenSSH returns directory entries in batches; several hundred forces more
            // than one, which is where a client that stops at the first page breaks.
            for index in 0 ..< 400 {
                let handle = try await client.open(
                    directory + "/file-\(String(format: "%03d", index))",
                    flags: [.write, .create], permissions: 0o600
                )
                try await client.closeHandle(handle)
            }
            let listing = try await client.listDirectory(directory)
            #expect(listing.count == 400, "got \(listing.count)")
            #expect(!listing.contains { $0.filename == "." || $0.filename == ".." }, "dot entries are not files")

            for entry in listing { try await client.remove(directory + "/" + entry.filename) }
            try await client.removeDirectory(directory)
        }
    }

    @Test("Rename is the commit step of an atomic write, and refuses to clobber")
    func atomicRename() async throws {
        try await withClient { client, server in
            let directory = self.scratch(server)
            try await client.makeDirectory(directory, permissions: 0o700)
            let temporary = directory + "/.upload.tmp"
            let final = directory + "/data.txt"

            let handle = try await client.open(temporary, flags: [.write, .create, .truncate], permissions: 0o600)
            try await client.write(handle: handle, offset: 0, bytes: Array("v1".utf8))
            try await client.closeHandle(handle)
            try await client.rename(from: temporary, to: final)
            #expect(try Data(contentsOf: URL(fileURLWithPath: final)) == Data("v1".utf8))

            // Version 3's rename fails rather than overwriting — which is exactly why it
            // can be used to commit, and why an overwrite has to remove first.
            let second = try await client.open(temporary, flags: [.write, .create, .truncate], permissions: 0o600)
            try await client.write(handle: second, offset: 0, bytes: Array("v2".utf8))
            try await client.closeHandle(second)
            await #expect(throws: SFTPError.self) {
                try await client.rename(from: temporary, to: final)
            }

            try await client.remove(temporary)
            try await client.remove(final)
            try await client.removeDirectory(directory)
        }
    }

    @Test("A missing file is refused with the reason, not a generic failure")
    func missingFile() async throws {
        try await withClient { client, _ in
            do {
                _ = try await client.attributes(of: "/definitely/not/here/\(UUID().uuidString)")
                Issue.record("stat of a missing path should not succeed")
            } catch let error as SFTPError {
                #expect(error.status == .noSuchFile, "got \(error)")
            }
        }
    }

    @Test("Symbolic links are reported as links, and their target is readable")
    func symbolicLinks() async throws {
        try await withClient { client, server in
            let directory = self.scratch(server)
            try await client.makeDirectory(directory, permissions: 0o700)
            let target = directory + "/target.txt"
            let handle = try await client.open(target, flags: [.write, .create], permissions: 0o600)
            try await client.closeHandle(handle)
            try FileManager.default.createSymbolicLink(atPath: directory + "/link", withDestinationPath: target)

            // lstat sees the link; stat follows it. Conflating the two is how a file
            // browser shows a link's size as the target's.
            let link = try await client.attributes(of: directory + "/link", followingLinks: false)
            #expect(link.isSymbolicLink)
            let followed = try await client.attributes(of: directory + "/link", followingLinks: true)
            #expect(followed.isRegularFile)
            #expect(try await client.readLink(directory + "/link") == target)

            try await client.remove(directory + "/link")
            try await client.remove(target)
            try await client.removeDirectory(directory)
        }
    }
}
