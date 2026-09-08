import Foundation
import NIOTransportServices
import STCore
import STSSH
import STTestSupport
import Testing

/// The ML-KEM hybrid key exchange, against a real OpenSSH server (D-048).
///
/// The assertion that matters is not that a handshake completed — a wrong construction can
/// complete against itself. It is that **OpenSSH's own log** says which algorithm it
/// negotiated, and that traffic then flowed under keys derived from it. If the encoding of
/// the shared secret were wrong by so much as a length prefix, the very next packet would
/// fail its MAC.
@Suite("Post-quantum key exchange against real OpenSSH", .serialized)
struct PostQuantumKeyExchangeTests {
    private func connect(to server: OpenSSHTestServer) async throws -> SSHConnection {
        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
        return try await SSHConnection.connect(
            transport: DirectTCPTransport(endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)),
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
    }

    @Test("A session is negotiated with mlkem768x25519-sha256 and carries real output")
    func hybridIsNegotiatedAndWorks() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            // Older systems have no ML-KEM to offer, and the classical exchange is used —
            // which is the designed behaviour, not a failure.
            return
        }
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }

        let connection = try await connect(to: server)
        // Keys derived from the exchange are what protect this command and its answer. A
        // shared secret encoded differently at either end fails the MAC on the next packet
        // rather than producing wrong output, so a correct answer here is the proof.
        let result = try await connection.execute(command: "printf PQ_OK")
        #expect(result.standardOutputText == "PQ_OK")
        await connection.close()

        // And the server says what it agreed to. The log is written by sshd, not by this
        // code, which is the point of reading it.
        let log = server.log()
        // sshd logs the algorithm it *chose*, on a line of the form
        // "debug1: kex: algorithm: mlkem768x25519-sha256". Matching that line rather than
        // the bare name matters: the log also lists everything the client offered, and a
        // looser check would pass even if the classical exchange had been chosen.
        let chosen = log.split(separator: "\n").filter { $0.contains("kex: algorithm:") }
        #expect(
            chosen.contains { $0.contains("mlkem768x25519-sha256") },
            "sshd chose: \(chosen.joined(separator: " | "))"
        )
    }

    @Test("A server that does not offer the hybrid still connects, on the classical exchange")
    func fallsBackWhenTheServerDoesNotOfferIt() async throws {
        // `KexAlgorithms` narrowed to the classical one: the client offers the hybrid
        // first and must accept being told no, rather than failing to negotiate.
        let server = try OpenSSHTestServer(kexAlgorithms: "curve25519-sha256")
        defer { server.shutDown() }

        let connection = try await connect(to: server)
        let result = try await connection.execute(command: "printf CLASSICAL_OK")
        #expect(result.standardOutputText == "CLASSICAL_OK")
        await connection.close()

        let log = server.log()
        let chosen = log.split(separator: "\n").filter { $0.contains("kex: algorithm:") }
        #expect(chosen.contains { $0.contains("curve25519-sha256") }, "sshd chose: \(chosen.joined(separator: " | "))")
        #expect(!chosen.contains { $0.contains("mlkem") })
    }
}
