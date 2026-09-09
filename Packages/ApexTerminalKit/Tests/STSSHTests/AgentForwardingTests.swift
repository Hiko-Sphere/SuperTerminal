import Crypto
import Foundation
import NIOCore
import NIOSSH
import NIOTransportServices
import STCore
@testable import STSSH
import STTestSupport
import Testing

/// Agent forwarding, with this device as the agent (D-052).
///
/// The proof is not that the code runs: it is that **OpenSSH's own `ssh-add`**, executed on
/// the server, talks to this app down a forwarded channel and lists the key. That exercises
/// the whole path — the `auth-agent-req@openssh.com` request, the server opening an
/// `auth-agent@openssh.com` channel back, the length framing, and the agent protocol
/// itself — against the implementation people actually use.
@Suite("Agent forwarding against real OpenSSH", .serialized)
struct AgentForwardingTests {
    private func identity(comment: String = "phone@apexterminal") throws -> (SSHAgent.Identity, SSHHostKey) {
        let generated = try SSHKeyGenerator.generate(algorithm: .ed25519, comment: comment)
        let material = try OpenSSHPrivateKeyParser.parse(pem: generated.privateKeyPEM)
        return (SSHAgent.Identity(key: material.key, comment: comment), material.publicKey)
    }

    @Test("`ssh-add -l` on the server lists a key that never left the device")
    func serverSideSSHAddSeesTheKey() async throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }

        let (agentIdentity, publicKey) = try identity()
        let connection = try await connect(to: server, agent: SSHAgent(identities: [agentIdentity]))
        defer { Task { await connection.close() } }

        // A shell, because agent forwarding is requested on the session channel and
        // SSH_AUTH_SOCK only exists for what the shell then runs.
        let shell = try await connection.openShell()
        // The marker is assembled by printf so that the shell's echo of this very line
        // does not contain it: matching the echo is how the first version of this test
        // "finished" before ssh-add had said anything.
        try await shell.send("ssh-add -l 2>&1; printf 'AGENT_%s\\n' DONE\n")
        let output = try await collect(from: shell, until: "AGENT_DONE")
        await shell.close()

        #expect(output.contains("AGENT_DONE"), "the command never finished; saw:\n\(output)")
        // The server's own log says whether it agreed to forward at all, which is the
        // first thing to know when ssh-add reports no agent.
        let serverLog = server.log()
        #expect(serverLog.contains("auth-agent-req"), "sshd never saw the request:\n\(serverLog.suffix(2000))")
        // `ssh-add -l` prints "<bits> <fingerprint> <comment> (<type>)". The fingerprint is
        // the one this device holds, so nothing else could have produced this line.
        #expect(
            output.contains(publicKey.fingerprintSHA256),
            "ssh-add did not list the forwarded key; it said:\n\(output)"
        )
        #expect(output.contains("phone@apexterminal"), "the comment should reach the server too:\n\(output)")
    }

    @Test("Without forwarding the server has no agent at all")
    func withoutForwardingThereIsNoAgent() async throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }

        // The control. Without it the test above could pass because the *machine running
        // the tests* has an agent that the server somehow reached.
        let connection = try await connect(to: server, agent: nil)
        defer { Task { await connection.close() } }

        let shell = try await connection.openShell()
        // The marker is assembled by printf so that the shell's echo of this very line
        // does not contain it: matching the echo is how the first version of this test
        // "finished" before ssh-add had said anything.
        try await shell.send("ssh-add -l 2>&1; printf 'AGENT_%s\\n' DONE\n")
        let output = try await collect(from: shell, until: "AGENT_DONE")
        await shell.close()

        #expect(output.contains("AGENT_DONE"), "saw:\n\(output)")
        #expect(
            output.contains("Could not open a connection") || output.contains("error fetching identities"),
            "with no forwarding, ssh-add should find no agent; it said:\n\(output)"
        )
    }

    @Test("A refused signature is a failure, not a signature")
    func policyCanRefuse() throws {
        let (agentIdentity, _) = try identity()
        let agent = SSHAgent(identities: [agentIdentity], policy: { _ in false })

        var request = ByteBufferAllocator().buffer(capacity: 128)
        request.writeInteger(SSHAgent.Message.signRequest)
        var blob = agentIdentity.key.publicKeyBlob
        request.writeInteger(UInt32(blob.readableBytes))
        request.writeBuffer(&blob)
        request.writeInteger(UInt32(4))
        request.writeString("data")
        request.writeInteger(UInt32(0))

        var reply = agent.answer(request: request)
        #expect(reply.readInteger(as: UInt8.self) == SSHAgent.Message.failure)
    }

    @Test("A key this device does not hold is refused rather than substituted")
    func unknownKeyIsRefused() throws {
        let (agentIdentity, _) = try identity()
        let (other, _) = try identity(comment: "somebody-else")
        let agent = SSHAgent(identities: [agentIdentity])

        var request = ByteBufferAllocator().buffer(capacity: 128)
        request.writeInteger(SSHAgent.Message.signRequest)
        var blob = other.key.publicKeyBlob
        request.writeInteger(UInt32(blob.readableBytes))
        request.writeBuffer(&blob)
        request.writeInteger(UInt32(4))
        request.writeString("data")
        request.writeInteger(UInt32(0))

        var reply = agent.answer(request: request)
        #expect(reply.readInteger(as: UInt8.self) == SSHAgent.Message.failure)
    }

    @Test("Adding or removing keys over a forwarded channel is refused")
    func remoteSideCannotChangeWhatThisDeviceHolds() throws {
        let (agentIdentity, _) = try identity()
        let agent = SSHAgent(identities: [agentIdentity])

        // SSH_AGENTC_ADD_IDENTITY (17) and SSH_AGENTC_REMOVE_IDENTITY (18). A forwarded
        // agent that honoured these would let the far side plant a key on the phone.
        for type in [UInt8(17), UInt8(18), UInt8(9), UInt8(19)] {
            var request = ByteBufferAllocator().buffer(capacity: 8)
            request.writeInteger(type)
            var reply = agent.answer(request: request)
            #expect(reply.readInteger(as: UInt8.self) == SSHAgent.Message.failure, "type \(type)")
        }
    }

    @Test("The identities answer is shaped the way the protocol says")
    func identitiesAnswerIsWellFormed() throws {
        let (agentIdentity, publicKey) = try identity(comment: "a comment")
        let agent = SSHAgent(identities: [agentIdentity])

        var request = ByteBufferAllocator().buffer(capacity: 8)
        request.writeInteger(SSHAgent.Message.requestIdentities)
        var reply = agent.answer(request: request)

        #expect(reply.readInteger(as: UInt8.self) == SSHAgent.Message.identitiesAnswer)
        #expect(reply.readInteger(as: UInt32.self) == 1)
        // Read into locals first: `#require` cannot take a mutating call on the buffer.
        let blobLength = reply.readInteger(as: UInt32.self)
        let length = try #require(blobLength)
        let blob = reply.readSlice(length: Int(length))
        let blobBytes = try #require(blob)
        // The blob must be the same bytes the app publishes as the public key, or the
        // server would ask to sign with something this device does not recognise.
        #expect(Data(blobBytes.readableBytesView) == publicKey.blob)
        let commentLength = reply.readInteger(as: UInt32.self)
        let commentBytes = try #require(commentLength)
        #expect(reply.readString(length: Int(commentBytes)) == "a comment")
        #expect(reply.readableBytes == 0, "nothing should follow the last identity")
    }

    /// Reads the shell until the marker shows up, or the session ends.
    private func collect(from shell: SSHShellSession, until marker: String) async throws -> String {
        let output = await shell.output
        let deadline = Date().addingTimeInterval(30)
        var text = ""
        for await event in output {
            if case let .output(data) = event {
                text += String(decoding: data, as: UTF8.self)
                if text.contains(marker) { return text }
            }
            if case .closed = event { return text }
            if Date() > deadline { return text }
        }
        return text
    }

    private func connect(to server: OpenSSHTestServer, agent: SSHAgent?) async throws -> SSHConnection {
        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
        return try await SSHConnection.connect(
            transport: DirectTCPTransport(endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)),
            configuration: SSHConnectionConfiguration(
                username: server.fixtures.username,
                credentials: [.privateKey(try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM))],
                knownHostIdentity: identity,
                agent: agent
            ),
            hostKeyVerifier: HostKeyVerifier(
                identity: identity,
                store: InMemoryKnownHostsStore(),
                approval: TrustOnFirstUseApproval()
            ),
            eventLoop: NIOTSEventLoopGroup.singleton.next()
        )
    }
}
