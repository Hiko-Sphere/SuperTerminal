import Foundation
import NIOCore
import NIOTransportServices
import STCloudflare
import STCore
import STSSH
import STTestSupport
import Testing

/// End-to-end tests against a real OpenSSH server.
///
/// Nothing here is simulated: `sshd` is the same binary a user's server runs, the
/// handshake is real, the crypto is real, and the commands really execute. A green run
/// means the client interoperates with OpenSSH, not that it agrees with a stub.
@Suite("SSH against real OpenSSH", .serialized)
struct SSHIntegrationTests {
    /// Boots a server and an event loop group, runs `body`, and always tears both
    /// down — including when the body throws, so a failing assertion cannot leave an
    /// `sshd` process or a loop thread behind for the next test to trip over.
    private func withServer<T>(_ body: (OpenSSHTestServer, NIOTSEventLoopGroup) async throws -> T) async throws -> T {
        let server = try OpenSSHTestServer()
        let group = NIOTSEventLoopGroup(loopCount: 1)
        do {
            let result = try await body(server, group)
            server.shutDown()
            try? await group.shutdownGracefully()
            return result
        } catch {
            server.shutDown()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private func connect(
        to server: OpenSSHTestServer,
        group: NIOTSEventLoopGroup,
        credentials: [SSHCredential],
        knownHosts: any KnownHostsStore = InMemoryKnownHostsStore(),
        approval: any HostKeyApprovalDelegate = TrustOnFirstUseApproval()
    ) async throws -> SSHConnection {
        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
        let verifier = HostKeyVerifier(identity: identity, store: knownHosts, approval: approval)
        return try await SSHConnection.connect(
            transport: DirectTCPTransport(
                endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)
            ),
            configuration: SSHConnectionConfiguration(
                username: server.fixtures.username,
                credentials: credentials,
                knownHostIdentity: identity
            ),
            hostKeyVerifier: verifier,
            eventLoop: group.next()
        )
    }

    @Test("Ed25519 key authentication reaches a real shell and runs a command")
    func ed25519KeyAuthenticationRunsCommand() async throws {
        try await withServer { server, group in
            let key = try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM)
            #expect(key.algorithm == "ssh-ed25519")

            let connection = try await connect(to: server, group: group, credentials: [.privateKey(key)])
            let result = try await connection.execute(command: "printf 'CF_E2E_OK\\n'")
            await connection.close()

            #expect(result.standardOutputText == "CF_E2E_OK\n")
            #expect(result.exitStatus == 0)
        }
    }

    @Test("ECDSA P-256 key authentication succeeds")
    func ecdsaKeyAuthentication() async throws {
        try await withServer { server, group in
            let key = try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientECDSAPrivateKeyPEM)
            #expect(key.algorithm == "ecdsa-sha2-nistp256")

            let connection = try await connect(to: server, group: group, credentials: [.privateKey(key)])
            let result = try await connection.execute(command: "printf 'ECDSA_OK\\n'")
            await connection.close()

            #expect(result.standardOutputText == "ECDSA_OK\n")
        }
    }

    @Test("A passphrase-protected key unlocks and authenticates")
    func encryptedKeyAuthentication() async throws {
        try await withServer { server, group in
            let inspection = try OpenSSHPrivateKeyParser.inspect(pem: server.fixtures.encryptedClientPrivateKeyPEM)
            #expect(inspection.isEncrypted)
            #expect(inspection.kdf == "bcrypt")

            #expect(throws: SSHKeyParseError.passphraseRequired) {
                _ = try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.encryptedClientPrivateKeyPEM)
            }
            #expect(throws: SSHKeyParseError.incorrectPassphrase) {
                _ = try OpenSSHPrivateKeyParser.parse(
                    pem: server.fixtures.encryptedClientPrivateKeyPEM,
                    passphrase: "wrong"
                )
            }

            let key = try OpenSSHPrivateKeyParser.parse(
                pem: server.fixtures.encryptedClientPrivateKeyPEM,
                passphrase: server.fixtures.clientKeyPassphrase
            )
            let connection = try await connect(to: server, group: group, credentials: [.privateKey(key)])
            let result = try await connection.execute(command: "printf 'ENCRYPTED_KEY_OK\\n'")
            await connection.close()

            #expect(result.standardOutputText == "ENCRYPTED_KEY_OK\n")
        }
    }

    @Test("An interactive PTY shell echoes typed input and reports the terminal size")
    func interactivePTYSession() async throws {
        try await withServer { server, group in
            let key = try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM)
            let connection = try await connect(to: server, group: group, credentials: [.privateKey(key)])
            let shell = try await connection.openShell(size: TerminalSize(columns: 132, rows: 43))

            // A PTY is what makes `stty size` meaningful; without one the command
            // fails, so this assertion is a real check that a terminal was allocated.
            try await shell.send("printf 'PTY_MARKER_%s\\n' \"$(stty size | awk '{print $2 \"x\" $1}')\"\n")

            let output = shell.output
            let text = try await withTimeout(seconds: 20) {
                var text = ""
                for await event in output {
                    if case let .output(data) = event {
                        text += String(decoding: data, as: UTF8.self)
                        if text.contains("PTY_MARKER_132x43") { return text }
                    }
                    if case .closed = event { return text }
                }
                return text
            }
            await shell.close()
            await connection.close()

            #expect(text.contains("PTY_MARKER_132x43"))
        }
    }

    @Test("Resizing the terminal is reflected on the remote side")
    func terminalResizePropagates() async throws {
        try await withServer { server, group in
            let key = try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM)
            let connection = try await connect(to: server, group: group, credentials: [.privateKey(key)])
            let shell = try await connection.openShell(size: TerminalSize(columns: 80, rows: 24))

            try await shell.resize(to: TerminalSize(columns: 100, rows: 40))
            // Give the remote shell a moment to process SIGWINCH before asking.
            try await Task.sleep(for: .milliseconds(300))
            try await shell.send("printf 'RESIZED_%s\\n' \"$(stty size | awk '{print $2 \"x\" $1}')\"\n")

            let output = shell.output
            let text = try await withTimeout(seconds: 20) {
                var text = ""
                for await event in output {
                    if case let .output(data) = event {
                        text += String(decoding: data, as: UTF8.self)
                        if text.contains("RESIZED_100x40") { return text }
                    }
                    if case .closed = event { return text }
                }
                return text
            }
            await shell.close()
            await connection.close()

            #expect(text.contains("RESIZED_100x40"))
        }
    }

    @Test("A wrong key is rejected with an authentication error, not a transport error")
    func wrongKeyIsRejected() async throws {
        try await withServer { server, group in
            // A freshly generated key that is deliberately not in authorized_keys.
            let strangerServer = try OpenSSHTestServer()
            defer { strangerServer.shutDown() }
            let stranger = try OpenSSHPrivateKeyParser.parse(pem: strangerServer.fixtures.clientPrivateKeyPEM)

            // `connect` must fail here, and must fail *promptly*: an exhausted
            // credential chain that waits for the server's LoginGraceTime would leave
            // the user staring at a spinner for two minutes.
            let started = Date()
            var caught: STError?
            do {
                let connection = try await connect(to: server, group: group, credentials: [.privateKey(stranger)])
                await connection.close()
            } catch let error as STError {
                caught = error
            }

            #expect(caught?.category == .sshAuthentication)
            #expect(Date().timeIntervalSince(started) < 15)
        }
    }

    @Test("A changed host key aborts the connection")
    func changedHostKeyAborts() async throws {
        try await withServer { server, group in
            let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
            // Seed the store with a key from a *different* server, so the real server's
            // key looks like a replacement.
            let otherServer = try OpenSSHTestServer()
            let impostorKey = try SSHHostKey(openSSHLine: otherServer.hostKeyOpenSSHLine)
            otherServer.shutDown()

            let store = InMemoryKnownHostsStore(seed: [
                KnownHostEntry(identity: identity, key: impostorKey, firstSeen: Date(), lastSeen: Date()),
            ])

            let key = try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM)
            var caught: STError?
            do {
                let connection = try await connect(
                    to: server,
                    group: group,
                    credentials: [.privateKey(key)],
                    knownHosts: store
                )
                await connection.close()
            } catch let error as STError {
                caught = error
            }

            #expect(caught?.category == .hostKey)
            // The recorded key must not have been silently replaced.
            let stored = try await store.entry(for: identity)
            #expect(stored?.key == impostorKey)
        }
    }

    @Test("Trust on first use records the server's real host key")
    func trustOnFirstUseRecordsKey() async throws {
        try await withServer { server, group in
            let store = InMemoryKnownHostsStore()
            let key = try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM)
            let connection = try await connect(
                to: server,
                group: group,
                credentials: [.privateKey(key)],
                knownHosts: store
            )
            _ = try await connection.execute(command: "true")
            await connection.close()

            let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
            let stored = try await store.entry(for: identity)
            let expected = try SSHHostKey(openSSHLine: server.hostKeyOpenSSHLine)
            #expect(stored?.key == expected)
            #expect(stored?.key.fingerprintSHA256 == expected.fingerprintSHA256)
        }
    }
}
