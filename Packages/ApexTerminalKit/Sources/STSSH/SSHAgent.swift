import Foundation
import NIOCore
import NIOSSH
import STCore

/// Answers the SSH agent protocol on behalf of keys this device holds.
///
/// iOS has no system SSH agent and no way for one app to publish a socket another can
/// connect to, so "use the local agent" is not a thing that exists here. The useful
/// direction is the other one: when agent forwarding is on, the *server* opens an
/// `auth-agent@openssh.com` channel back and asks this app to sign. A `git push` on the
/// server is then authenticated by a key that never left the phone — including a Secure
/// Enclave key, which cannot leave it at all.
///
/// Only two requests are answered, which is all `ssh-add -l` and public-key authentication
/// need:
///
/// * `SSH_AGENTC_REQUEST_IDENTITIES` (11) → `SSH_AGENT_IDENTITIES_ANSWER` (12)
/// * `SSH_AGENTC_SIGN_REQUEST` (13) → `SSH_AGENT_SIGN_RESPONSE` (14)
///
/// Everything else is answered `SSH_AGENT_FAILURE`. Adding and removing keys over the
/// forwarded channel is deliberately not implemented: the remote side has no business
/// changing what this device holds, and a forwarded agent that accepts `ADD_IDENTITY` is a
/// way to plant a key on someone's phone.
///
/// The protocol is draft-miller-ssh-agent, the specification OpenSSH implements.
public struct SSHAgent: Sendable {
    /// What the agent will sign with, and the comment shown by `ssh-add -l`.
    public struct Identity: Sendable {
        public let key: NIOSSHPrivateKey
        public let comment: String

        public init(key: NIOSSHPrivateKey, comment: String) {
            self.key = key
            self.comment = comment
        }
    }

    /// Called before each signature, with the comment of the key being asked for.
    ///
    /// Returning false refuses the request. This is the hook a UI uses to ask, or to
    /// enforce a policy: the whole risk of agent forwarding is that something on the far
    /// side can ask for a signature at a moment of its choosing.
    public typealias SigningPolicy = @Sendable (Identity) -> Bool

    private let identities: [Identity]
    private let policy: SigningPolicy
    private let log: STLogger

    public init(
        identities: [Identity],
        policy: @escaping SigningPolicy = { _ in true },
        log: STLogger = .disabled
    ) {
        self.identities = identities
        self.policy = policy
        self.log = log.child(subsystem: "ssh.agent")
    }

    // MARK: - Message numbers

    enum Message {
        static let failure: UInt8 = 5
        static let success: UInt8 = 6
        static let requestIdentities: UInt8 = 11
        static let identitiesAnswer: UInt8 = 12
        static let signRequest: UInt8 = 13
        static let signResponse: UInt8 = 14
    }

    /// Signature flags a client may ask for (draft-miller-ssh-agent § 5.3).
    enum SignFlags {
        static let rsaSHA2_256: UInt32 = 2
        static let rsaSHA2_512: UInt32 = 4
    }

    /// The largest request this agent will read before giving up on the peer.
    ///
    /// A forwarded agent channel is fed by whatever is on the far side, so the length
    /// prefix is not to be trusted: OpenSSH's own agent caps a message at 256 KiB.
    static let maximumMessageLength = 256 * 1024

    // MARK: - Answering

    /// Answers one agent request, returning the reply body without its length prefix.
    ///
    /// - Returns: `nil` only when the request is malformed past the point of replying;
    ///   every request this agent understands but will not perform gets an explicit
    ///   `SSH_AGENT_FAILURE`, because silence looks to a client like a hang.
    public func answer(request: ByteBuffer) -> ByteBuffer {
        var request = request
        guard let type = request.readInteger(as: UInt8.self) else { return Self.failureReply() }

        switch type {
        case Message.requestIdentities:
            return identitiesReply()
        case Message.signRequest:
            return signReply(&request)
        default:
            log.debug("refusing an agent request", ["type": "\(type)"])
            return Self.failureReply()
        }
    }

    private func identitiesReply() -> ByteBuffer {
        var reply = ByteBufferAllocator().buffer(capacity: 256)
        reply.writeInteger(Message.identitiesAnswer)
        reply.writeInteger(UInt32(identities.count))
        for identity in identities {
            var blob = identity.key.publicKeyBlob
            reply.writeInteger(UInt32(blob.readableBytes))
            reply.writeBuffer(&blob)
            reply.writeInteger(UInt32(identity.comment.utf8.count))
            reply.writeString(identity.comment)
        }
        log.info("listed identities", ["count": "\(identities.count)"])
        return reply
    }

    private func signReply(_ request: inout ByteBuffer) -> ByteBuffer {
        guard
            let keyBlobLength = request.readInteger(as: UInt32.self),
            keyBlobLength <= UInt32(Self.maximumMessageLength),
            let keyBlob = request.readSlice(length: Int(keyBlobLength)),
            let dataLength = request.readInteger(as: UInt32.self),
            dataLength <= UInt32(Self.maximumMessageLength),
            let data = request.readSlice(length: Int(dataLength)),
            let flags = request.readInteger(as: UInt32.self)
        else {
            return Self.failureReply()
        }

        // Which key, by its blob. Comparing blobs rather than fingerprints because that is
        // what the client sent and what it will check the signature against.
        let wanted = Data(keyBlob.readableBytesView)
        guard let identity = identities.first(where: { Data($0.key.publicKeyBlob.readableBytesView) == wanted })
        else {
            log.info("asked to sign with a key this device does not hold")
            return Self.failureReply()
        }

        guard policy(identity) else {
            log.info("a signature was refused by policy", ["key": identity.comment])
            return Self.failureReply()
        }

        // RSA's algorithm name travels in the signature, so the client's flags decide it.
        // Without either flag the request means the legacy SHA-1 variant, which this
        // library does not produce and no current server should ask for; SHA-256 is used
        // rather than failing, because that is what OpenSSH's agent does when asked by an
        // old client and it is strictly the safer of the two.
        let rsaAlgorithm: NIOSSHRSASignatureAlgorithm =
            (flags & SignFlags.rsaSHA2_512) != 0 ? .sha512 : .sha256

        do {
            var signature = try identity.key.signOpaqueAgentRequest(data, rsaAlgorithm: rsaAlgorithm)
            var reply = ByteBufferAllocator().buffer(capacity: signature.readableBytes + 8)
            reply.writeInteger(Message.signResponse)
            reply.writeBuffer(&signature)
            log.info("signed for a forwarded agent", ["key": identity.comment])
            return reply
        } catch {
            log.error("could not sign", ["error": String(describing: error)])
            return Self.failureReply()
        }
    }

    static func failureReply() -> ByteBuffer {
        var reply = ByteBufferAllocator().buffer(capacity: 1)
        reply.writeInteger(Message.failure)
        return reply
    }
}

/// Frames the agent protocol onto an `auth-agent@openssh.com` channel.
///
/// The protocol is length-prefixed messages in both directions, and a channel delivers
/// arbitrary fragments, so this accumulates until a whole request is present.
final class SSHAgentChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = Never
    typealias OutboundOut = SSHChannelData

    private let agent: SSHAgent
    private var buffer: ByteBuffer
    private let log: STLogger

    init(agent: SSHAgent, allocator: ByteBufferAllocator, log: STLogger) {
        self.agent = agent
        buffer = allocator.buffer(capacity: 512)
        self.log = log
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = channelData.data, channelData.type == .channel else { return }
        buffer.writeBuffer(&bytes)

        while true {
            // Peek at the length without consuming it: a partial message must stay whole
            // in the buffer until the rest arrives.
            guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else { return }
            guard length <= UInt32(SSHAgent.maximumMessageLength), length > 0 else {
                // The far side is either broken or hostile. Closing is the only safe move:
                // there is no way to resynchronise a length-prefixed stream.
                log.error("agent message length out of range", ["length": "\(length)"])
                context.close(promise: nil)
                return
            }
            guard buffer.readableBytes >= Int(length) + 4 else { return }

            buffer.moveReaderIndex(forwardBy: 4)
            guard let request = buffer.readSlice(length: Int(length)) else { return }
            buffer.discardReadBytes()

            var reply = agent.answer(request: request)
            var framed = context.channel.allocator.buffer(capacity: reply.readableBytes + 4)
            framed.writeInteger(UInt32(reply.readableBytes))
            framed.writeBuffer(&reply)
            context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(framed))), promise: nil)
        }
    }
}
