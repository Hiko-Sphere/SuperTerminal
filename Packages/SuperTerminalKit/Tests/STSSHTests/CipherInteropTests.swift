import Foundation
import NIOTransportServices
import STCore
import STSSH
import STTestSupport
import Testing

/// Cipher negotiation, proved by removing the alternatives.
///
/// Asserting that a connection "used AES-CTR" from the client side is circular — the
/// client would be reporting on itself. Configuring the server to offer *only* one scheme
/// makes the connection itself the evidence: it either negotiates that scheme or it does
/// not happen.
@Suite("Cipher interoperability", .serialized)
struct CipherInteropTests {
    private func connectAndRun(
        _ server: OpenSSHTestServer,
        marker: String
    ) async throws -> String {
        let group = NIOTSEventLoopGroup.singleton
        do {
            let key = try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM)
            let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
            let connection = try await SSHConnection.connect(
                transport: DirectTCPTransport(
                    endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)
                ),
                configuration: SSHConnectionConfiguration(
                    username: server.fixtures.username,
                    credentials: [.privateKey(key)],
                    knownHostIdentity: identity
                ),
                hostKeyVerifier: HostKeyVerifier(
                    identity: identity,
                    store: InMemoryKnownHostsStore(),
                    approval: TrustOnFirstUseApproval()
                ),
                eventLoop: group.next()
            )
            let result = try await connection.execute(command: "printf '\(marker)\\n'")
            await connection.close()
            return result.standardOutputText
        } catch {
            throw error
        }
    }

    @Test("A server offering only AES-CTR with encrypt-then-MAC can be reached")
    func aesCTRWithETMOnly() async throws {
        // No AES-GCM at all, so success can only have come through the CTR scheme.
        let server = try OpenSSHTestServer(
            ciphers: (ciphers: "aes256-ctr", macs: "hmac-sha2-256-etm@openssh.com")
        )
        defer { server.shutDown() }
        let output = try await connectAndRun(server, marker: "AES_CTR_ETM_OK")
        #expect(output == "AES_CTR_ETM_OK\n")
    }

    @Test("A long session over AES-CTR stays in sync")
    func counterStaysInSyncAcrossManyPackets() async throws {
        // CTR is a stream cipher: if the counter is advanced wrongly, the first packet
        // works and everything after it is garbage. A single command would not notice.
        let server = try OpenSSHTestServer(
            ciphers: (ciphers: "aes256-ctr", macs: "hmac-sha2-256-etm@openssh.com")
        )
        defer { server.shutDown() }

        let group = NIOTSEventLoopGroup.singleton
        do {
            let key = try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM)
            let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
            let connection = try await SSHConnection.connect(
                transport: DirectTCPTransport(
                    endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)
                ),
                configuration: SSHConnectionConfiguration(
                    username: server.fixtures.username,
                    credentials: [.privateKey(key)],
                    knownHostIdentity: identity
                ),
                hostKeyVerifier: HostKeyVerifier(
                    identity: identity,
                    store: InMemoryKnownHostsStore(),
                    approval: TrustOnFirstUseApproval()
                ),
                eventLoop: group.next()
            )

            // A burst large enough to span many packets in both directions.
            let result = try await connection.execute(
                command: "head -c 400000 /dev/zero | tr '\\0' 'q'; printf '\\nCTR_BURST_%s\\n' DONE"
            )
            await connection.close()

            #expect(result.standardOutputText.contains("CTR_BURST_DONE"))
            #expect(result.standardOutput.count > 400_000)
        } catch {
            throw error
        }
    }

    @Test("A server offering only chacha20-poly1305 can be reached")
    func chacha20Poly1305Only() async throws {
        // No AES at all, so success can only have come through the chacha20 scheme — and
        // through the RFC 4253 § 7.2 key extension it depends on, since this is the only
        // cipher that asks for more key than one SHA-256 digest provides. `MACs` is set
        // because the harness writes both lines; sshd ignores it for an AEAD cipher.
        let server = try OpenSSHTestServer(
            ciphers: (ciphers: "chacha20-poly1305@openssh.com", macs: "hmac-sha2-256-etm@openssh.com")
        )
        defer { server.shutDown() }
        let output = try await connectAndRun(server, marker: "CHACHA20_POLY1305_OK")
        #expect(output == "CHACHA20_POLY1305_OK\n")
    }

    @Test("A long session over chacha20-poly1305 stays in sync")
    func chacha20NonceStaysInSyncAcrossManyPackets() async throws {
        // The nonce is the packet sequence number. If either side numbered a packet
        // wrongly the tag fails and the session dies. One command would not notice;
        // hundreds of packets in both directions do.
        let server = try OpenSSHTestServer(
            ciphers: (ciphers: "chacha20-poly1305@openssh.com", macs: "hmac-sha2-256-etm@openssh.com")
        )
        defer { server.shutDown() }

        let group = NIOTSEventLoopGroup.singleton
        do {
            let key = try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM)
            let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
            let connection = try await SSHConnection.connect(
                transport: DirectTCPTransport(
                    endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)
                ),
                configuration: SSHConnectionConfiguration(
                    username: server.fixtures.username,
                    credentials: [.privateKey(key)],
                    knownHostIdentity: identity
                ),
                hostKeyVerifier: HostKeyVerifier(
                    identity: identity,
                    store: InMemoryKnownHostsStore(),
                    approval: TrustOnFirstUseApproval()
                ),
                eventLoop: group.next()
            )
            // A burst large enough to span many packets in both directions.
            let result = try await connection.execute(
                command: "head -c 400000 /dev/zero | tr '\\0' 'c'; printf '\\nCHACHA_BURST_%s\\n' DONE"
            )
            await connection.close()

            #expect(result.standardOutputText.contains("CHACHA_BURST_DONE"))
            #expect(result.standardOutput.count > 400_000)
        } catch {
            throw error
        }
    }

    @Test("AES-GCM is still preferred when both are on offer")
    func gcmRemainsAvailable() async throws {
        let server = try OpenSSHTestServer(
            ciphers: (
                ciphers: "aes256-gcm@openssh.com,aes256-ctr",
                macs: "hmac-sha2-256-etm@openssh.com,hmac-sha2-256"
            )
        )
        defer { server.shutDown() }
        let output = try await connectAndRun(server, marker: "GCM_STILL_OK")
        #expect(output == "GCM_STILL_OK\n")
    }
}

/// The counter arithmetic on its own. An off-by-one here produces a session that works for
/// exactly one packet, which is a miserable thing to diagnose from the outside.
@Suite("AES-CTR counter arithmetic")
struct AESCTRCounterTests {
    private func counter(_ bytes: [UInt8]) -> [UInt8] {
        Array(repeating: 0, count: 16 - bytes.count) + bytes
    }

    @Test("Advancing by zero leaves the counter alone")
    func zeroIsIdentity() {
        let start = counter([0x01, 0x02])
        #expect(AES256CTRSHA256ETMTransportProtection.advancing(start, byBlocks: 0) == start)
    }

    @Test("Advancing counts blocks, not bytes")
    func advancesByBlocks() {
        #expect(
            AES256CTRSHA256ETMTransportProtection.advancing(counter([0x00]), byBlocks: 5)
                == counter([0x05])
        )
    }

    @Test("A carry propagates across byte boundaries")
    func carryPropagates() {
        #expect(
            AES256CTRSHA256ETMTransportProtection.advancing(counter([0xFF]), byBlocks: 1)
                == counter([0x01, 0x00])
        )
        #expect(
            AES256CTRSHA256ETMTransportProtection.advancing(counter([0xFF, 0xFF]), byBlocks: 1)
                == counter([0x01, 0x00, 0x00])
        )
    }

    @Test("A large increment carries correctly")
    func largeIncrement() {
        // 0x0100 blocks past 0xFFFF is 0x0100FF.
        #expect(
            AES256CTRSHA256ETMTransportProtection.advancing(counter([0xFF, 0xFF]), byBlocks: 0x100)
                == counter([0x01, 0x00, 0xFF])
        )
    }

    @Test("The counter wraps rather than trapping")
    func wrapsAtTheTop() {
        let allOnes = [UInt8](repeating: 0xFF, count: 16)
        // The block cipher's counter is modular; trapping here would crash a long session
        // rather than behaving as AES-CTR specifies.
        #expect(AES256CTRSHA256ETMTransportProtection.advancing(allOnes, byBlocks: 1) == [UInt8](repeating: 0, count: 16))
    }
}
