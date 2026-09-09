import Foundation
import NIOCore
import NIOSSH
import STCore

/// Everything needed to open an SSH connection, independent of which transport
/// carries it.
public struct SSHConnectionConfiguration: Sendable {
    public var username: String
    public var credentials: [SSHCredential]
    /// The identity host keys are remembered against.
    public var knownHostIdentity: KnownHostIdentity
    /// How often the transport probes liveness while the connection is idle.
    ///
    /// SSH-level keepalive requests are not used: NIOSSH does not expose the global
    /// request API needed to send `keepalive@openssh.com`. Liveness is instead probed
    /// by the transport — TCP keepalive for a direct connection, WebSocket ping frames
    /// for the Cloudflare carrier — which detects the same failures (a peer that
    /// vanished without a FIN, a dropped NAT mapping) and additionally keeps the
    /// carrier's idle timer from expiring.
    public var keepAliveInterval: TimeAmount
    /// How long the handshake and authentication may take in total.
    public var handshakeTimeout: TimeAmount
    /// Asked for a password when the stored credentials are spent and the server takes
    /// one (D-024). `nil` means the attempt fails there instead.
    public var passwordProvider: SSHPasswordProvider?
    /// Answers the server's own questions when it offers keyboard-interactive (D-051).
    ///
    /// Not a stored credential and not something the user configures: it is the method by
    /// which a server *asks*, so a host with two-factor authentication works without
    /// anything being set up for it. `nil` means the method is never offered.
    public var keyboardInteractiveResponder: SSHKeyboardInteractiveResponder?
    /// The agent to answer with when the far side asks (D-052).
    ///
    /// `nil` — the default — means agent forwarding is off and an `auth-agent@openssh.com`
    /// channel is refused like any other unrequested one. Setting it is what makes this
    /// device sign for processes on the server.
    public var agent: SSHAgent?

    public init(
        username: String,
        credentials: [SSHCredential],
        knownHostIdentity: KnownHostIdentity,
        keepAliveInterval: TimeAmount = .seconds(30),
        handshakeTimeout: TimeAmount = .seconds(30),
        passwordProvider: SSHPasswordProvider? = nil,
        keyboardInteractiveResponder: SSHKeyboardInteractiveResponder? = nil,
        agent: SSHAgent? = nil
    ) {
        self.username = username
        self.credentials = credentials
        self.knownHostIdentity = knownHostIdentity
        self.keepAliveInterval = keepAliveInterval
        self.handshakeTimeout = handshakeTimeout
        self.passwordProvider = passwordProvider
        self.keyboardInteractiveResponder = keyboardInteractiveResponder
        self.agent = agent
    }
}

/// Terminal geometry, in both character cells and pixels.
public struct TerminalSize: Sendable, Equatable {
    public var columns: Int
    public var rows: Int
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.pixelWidth = max(0, pixelWidth)
        self.pixelHeight = max(0, pixelHeight)
    }

    public static let `default` = TerminalSize(columns: 80, rows: 24)
}

/// A live SSH connection. Channels are opened from it; it does not itself carry data.
public actor SSHConnection {
    private let channel: Channel
    private let handler: EventLoopIsolated<NIOSSHHandler>
    private let credentialChain: SSHCredentialChain
    internal let log: STLogger
    private var closed = false
    /// Connections this one is carried through — the jump hosts (D-047).
    ///
    /// Held so that closing this connection closes the chain behind it. Without that a
    /// bastion session would stay open after the session it existed for had gone, which
    /// on a bastion with a session limit is a slow way to lock yourself out.
    private var carriers: [SSHConnection] = []
    /// Where `forwarded-tcpip` channels go (D-045). Created before the handler, because
    /// the handler needs it to decide whether to accept one.
    internal let forwardedChannels: ForwardedChannelRouter

    /// The loop that owns the connection.
    ///
    /// Public because port forwarding needs it (D-045): a forwarded connection is two
    /// channels glued together, and the glue reaches across from one to the other, which
    /// is only safe if both are on the same loop. Callers put their end of the pair here.
    public nonisolated var eventLoop: EventLoop { channel.eventLoop }
    internal nonisolated var sshHandler: EventLoopIsolated<NIOSSHHandler> { handler }

    /// Set when this connection offered to be the far side's agent (D-052). Kept so the
    /// shell knows to ask for forwarding, and so the answer to "is anything signing on my
    /// behalf over there?" has one place to come from.
    internal let agent: SSHAgent?

    private init(
        channel: Channel,
        handler: EventLoopIsolated<NIOSSHHandler>,
        credentialChain: SSHCredentialChain,
        forwardedChannels: ForwardedChannelRouter,
        agent: SSHAgent?,
        log: STLogger
    ) {
        self.channel = channel
        self.handler = handler
        self.credentialChain = credentialChain
        self.forwardedChannels = forwardedChannels
        self.agent = agent
        self.log = log
    }

    /// Runs the SSH transport handshake and user authentication over `transport`.
    ///
    /// Both supported transports — direct TCP and the Cloudflare Access carrier —
    /// reach this same code path, which is the point: once a byte stream exists, the
    /// SSH layer is identical, and there is exactly one implementation of host key
    /// verification, authentication and channel handling to review.
    public static func connect(
        transport: any ByteStreamTransport,
        configuration: SSHConnectionConfiguration,
        hostKeyVerifier: HostKeyVerifier,
        eventLoop: EventLoop,
        log: STLogger = .disabled
    ) async throws -> SSHConnection {
        let log = log.child(subsystem: "ssh.connection")
        log.info("opening SSH connection", ["transport": transport.transportDescription])

        let channel = try await transport.connect(on: eventLoop)
        let chain = SSHCredentialChain(
            username: configuration.username,
            credentials: configuration.credentials,
            passwordProvider: configuration.passwordProvider,
            keyboardInteractiveResponder: configuration.keyboardInteractiveResponder,
            log: log
        )
        // The handler is constructed *inside* the event loop and never leaves it:
        // NIOSSHHandler is a mutable state machine that is deliberately not Sendable,
        // so the only safe place to build and install it is the loop that owns it.
        let readyPromise = channel.eventLoop.makePromise(of: Void.self)
        let monitor = SSHHandshakeMonitor(readyPromise: readyPromise, log: log)
        let forwardedChannels = ForwardedChannelRouter()

        let handlerBox: EventLoopIsolated<NIOSSHHandler>
        do {
            handlerBox = try await channel.eventLoop.submit {
                let sshHandler = NIOSSHHandler(
                    role: .client(
                        SSHClientConfiguration(
                            userAuthDelegate: chain,
                            serverAuthDelegate: hostKeyVerifier,
                            transportProtectionSchemes: Self.transportProtectionSchemes
                        )
                    ),
                    allocator: channel.allocator,
                    // Server-opened channels are refused unless a remote forward asked
                    // for them (D-045). Passing `nil` here would refuse all of them,
                    // which was right until remote forwarding existed and would now
                    // silently break it; accepting all of them would let a server open
                    // connections into the app that nothing requested.
                    inboundChildChannelInitializer: { child, type in
                        // The agent channel, when this connection offered one. Anything
                        // else of this type is refused: a server that opens it without
                        // having been asked is asking to be signed for by a device that
                        // never agreed to it.
                        if case .authAgent = type {
                            guard let agent = configuration.agent else {
                                log.info("refused an agent channel that was never requested")
                                return child.eventLoop.makeFailedFuture(SSHConnection.unexpectedInboundChannel)
                            }
                            log.debug("the server opened an agent channel")
                            return child.eventLoop.makeCompletedFuture {
                                try child.pipeline.syncOperations.addHandler(
                                    SSHAgentChannelHandler(
                                        agent: agent,
                                        allocator: child.allocator,
                                        log: log
                                    )
                                )
                            }
                        }

                        guard case let .forwardedTCPIP(forwarded) = type,
                              let route = forwardedChannels.route(
                                  host: forwarded.listeningHost,
                                  port: forwarded.listeningPort
                              )
                        else {
                            log.info("refused a channel the server opened", ["type": String(describing: type)])
                            return child.eventLoop.makeFailedFuture(SSHConnection.unexpectedInboundChannel)
                        }
                        log.debug("accepted a forwarded connection", [
                            "host": forwarded.listeningHost,
                            "port": "\(forwarded.listeningPort)",
                        ])
                        // The route is called inside the initialiser, before the channel
                        // is active, so it can install a handler in time to catch what
                        // the server sends first. Switching `autoRead` off here would not
                        // help: a child channel takes that from its parent when it
                        // activates, and would turn it straight back on.
                        return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                            .flatMap { child.pipeline.addHandler(SSHDataToByteBufferCodec()) }
                            .map { route(child, forwarded) }
                    }
                )
                try channel.pipeline.syncOperations.addHandlers([sshHandler, monitor])
                // A peer that accepts and immediately closes — a health-check port, a
                // load balancer with no backend, a firewall that resets as soon as the
                // handshake starts — can be gone before these handlers are installed, in
                // which case `channelInactive` was delivered to a pipeline that did not
                // contain the monitor yet. Checking here closes that window; without it
                // the attempt waits out the whole handshake timeout for an answer that
                // had already arrived.
                return EventLoopIsolated(sshHandler, eventLoop: channel.eventLoop)
            }.get()
        } catch {
            // The promise was made before the handlers went in, and nothing has taken it
            // over yet — so failing it here is what stops it being deallocated unfulfilled.
            // NIO checks for exactly that in a debug build and traps; in release it is a
            // promise nobody will ever complete. This path is reached when a peer accepts
            // and closes before the pipeline is built, which is a health-check port, a load
            // balancer with no backend, or a server being restarted underneath a retry.
            readyPromise.fail(error)
            try? await channel.close().get()
            throw STError(
                category: .sshTransport,
                message: String(localized: "Could not start the SSH session.", bundle: .module),
                underlyingDescription: String(describing: error)
            )
        }

        // The timeout is armed on the event loop rather than as a racing Swift task.
        // `EventLoopFuture.get()` does not observe task cancellation, so a task-group
        // race would leave the losing child suspended forever and the group would never
        // drain — a hang instead of a timeout.
        let timeout = channel.eventLoop.scheduleTask(in: configuration.handshakeTimeout) {
            // Network, not transport: the server did not answer. That is the kind of
            // failure a retry can fix, and categorising it with key exchange failures
            // would mean the app never retried a slow or unreachable host.
            readyPromise.fail(STError(
                category: .network,
                message: String(localized: "The SSH handshake did not complete in time.", bundle: .module),
                recoverySuggestion: String(localized: "Check that the server is reachable and really is an SSH server, then try again.", bundle: .module)
            ))
        }
        readyPromise.futureResult.whenComplete { _ in timeout.cancel() }

        // Wait for the handshake to actually finish, so a caller that gets a connection
        // back knows it is authenticated — and one that does not gets the real reason
        // rather than a generic failure later on.
        do {
            try await readyPromise.futureResult.get()
        } catch {
            try? await channel.close().get()
            throw classifyHandshakeFailure(
                monitor.recordedError ?? error,
                lastOffered: chain.mostRecentlyOffered,
                identity: configuration.knownHostIdentity
            )
        }

        return SSHConnection(
            channel: channel,
            handler: handlerBox,
            credentialChain: chain,
            forwardedChannels: forwardedChannels,
            agent: configuration.agent,
            log: log
        )
    }

    /// The ciphers offered, strongest first.
    ///
    /// AES-GCM is preferred; every OpenSSH since 6.2 offers it. AES-CTR with
    /// encrypt-then-MAC is included because hardening guides routinely narrow a server's
    /// `Ciphers` list to the CTR family, and such a server would otherwise be unreachable
    /// however modern it is. See ``AES256CTRSHA256ETMTransportProtection``.
    static var transportProtectionSchemes: [NIOSSHTransportProtection.Type] {
        // Order is preference. AES-GCM stays first: every iPhone has AES in hardware, so it
        // is both the fastest and the one upstream maintains. chacha20-poly1305 follows,
        // for servers narrowed to it; AES-CTR last, for the hardening guides that keep only
        // the CTR family.
        Constants.bundledTransportProtectionSchemesErased + [
            ChaCha20Poly1305TransportProtection.self,
            AES256CTRSHA256ETMTransportProtection.self,
        ]
    }

    /// Refuses a channel the server opened that no forward asked for.
    static let unexpectedInboundChannel = STError(
        category: .sshChannel,
        message: "The server tried to open a channel that was not requested."
    )

    /// The transport channel's closed future, so callers can observe disconnection.
    public var closeFuture: EventLoopFuture<Void> { channel.closeFuture }

    public func waitUntilClosed() async {
        try? await channel.closeFuture.get()
    }

    /// Opens an interactive shell with a PTY.
    public func openShell(
        terminalType: String = "xterm-256color",
        size: TerminalSize = .default,
        environment: [String: String] = [:]
    ) async throws -> SSHShellSession {
        let child = try await createSessionChannel()
        let stream = try await Self.attachStream(to: child)

        do {
            try await Self.request(
                on: child,
                event: SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: terminalType,
                    terminalCharacterWidth: size.columns,
                    terminalRowHeight: size.rows,
                    terminalPixelWidth: size.pixelWidth,
                    terminalPixelHeight: size.pixelHeight,
                    terminalModes: SSHTerminalModes([:])
                ),
                failureCategory: .sshChannel,
                failureMessage: String(localized: "The server refused to allocate a terminal.", bundle: .module)
            )
            if agent != nil {
                // Asked before the shell starts, so the environment the shell inherits
                // already has SSH_AUTH_SOCK in it. A server that refuses is not an error:
                // plenty have `AllowAgentForwarding no`, and the session is still usable
                // without it — it just cannot sign for anything on the far side.
                do {
                    try await Self.request(
                        on: child,
                        event: SSHChannelRequestEvent.AgentForwardingRequest(wantReply: true),
                        failureCategory: .sshChannel,
                        failureMessage: String(localized: "The server refused to forward the agent.", bundle: .module)
                    )
                    log.info("agent forwarding accepted by the server")
                } catch {
                    log.info("the server refused agent forwarding", ["error": String(describing: error)])
                }
            }
            for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
                // Servers commonly refuse env requests they have not allowlisted;
                // that is not fatal, so failures are logged and the session continues.
                try? await Self.request(
                    on: child,
                    event: SSHChannelRequestEvent.EnvironmentRequest(wantReply: true, name: name, value: value),
                    failureCategory: .sshChannel,
                    failureMessage: String(localized: "The server refused an environment variable.", bundle: .module)
                )
            }
            try await Self.request(
                on: child,
                event: SSHChannelRequestEvent.ShellRequest(wantReply: true),
                failureCategory: .sshChannel,
                failureMessage: String(localized: "The server refused to start a shell.", bundle: .module)
            )
        } catch {
            try? await child.close().get()
            throw error
        }

        log.info("interactive shell opened", ["cols": "\(size.columns)", "rows": "\(size.rows)"])
        return SSHShellSession(channel: child, output: stream, log: log)
    }

    /// Runs a command and hands back its stream, rather than collecting it.
    ///
    /// `execute` waits for the command to finish, which is wrong for anything that keeps
    /// talking — tmux in control mode, most of all (D-057). No pseudo-terminal is
    /// requested: a program that speaks a protocol on stdout wants its bytes, not a
    /// terminal's echo and line discipline in front of them.
    public func openCommand(_ command: String) async throws -> SSHShellSession {
        let child = try await createSessionChannel()
        let stream = try await Self.attachStream(to: child)
        do {
            try await Self.request(
                on: child,
                event: SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
                failureCategory: .sshChannel,
                failureMessage: String(localized: "The server refused to run the command.", bundle: .module)
            )
        } catch {
            try? await child.close().get()
            throw error
        }
        log.info("command channel opened")
        return SSHShellSession(channel: child, output: stream, log: log)
    }

    /// Runs a single command and collects its output.
    ///
    /// Used by the end-to-end verification path, where a known string must come back
    /// from the real remote host for the test to mean anything.
    public func execute(command: String, timeout: Duration = .seconds(30)) async throws -> SSHCommandResult {
        let child = try await createSessionChannel()
        let stream = try await Self.attachStream(to: child)
        try await Self.request(
            on: child,
            event: SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
            failureCategory: .sshChannel,
            failureMessage: String(localized: "The server refused to run the command.", bundle: .module)
        )

        let collector = Task { () -> (Data, Data, Int?) in
            var standardOutput = Data()
            var standardError = Data()
            var exitStatus: Int?
            for await event in stream {
                switch event {
                case let .output(data): standardOutput.append(data)
                case let .errorOutput(data): standardError.append(data)
                case let .exit(status): exitStatus = status
                case .closed: return (standardOutput, standardError, exitStatus)
                }
            }
            return (standardOutput, standardError, exitStatus)
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            collector.cancel()
        }
        let (standardOutput, standardError, exitStatus) = await collector.value
        timeoutTask.cancel()
        try? await child.close().get()

        return SSHCommandResult(
            standardOutput: standardOutput,
            standardError: standardError,
            exitStatus: exitStatus
        )
    }

    /// Opens a TCP forward through this connection to `host:port` as seen from the
    /// server, returning the channel as a raw byte pipe. The caller adds its own
    /// handlers; the SSH data handler that turns channel data into bytes is installed
    /// here, because every consumer needs it.
    public func openDirectTCPIP(host: String, port: Int) async throws -> Channel {
        try await openDirectTCPIP(host: host, port: port) { $0.eventLoop.makeSucceededVoidFuture() }
    }

    /// The same, with a chance to configure the channel *before* it is active.
    ///
    /// Port forwarding needs this (D-045): a service that speaks first — SMTP, IMAP, an
    /// SSH server behind the forward — sends its greeting the moment the channel opens,
    /// and a handler added afterwards would arrive to find those bytes already delivered
    /// to a pipeline that had nowhere to put them. `configure` runs inside the channel
    /// initialiser, which is the only point that is definitively early enough.
    public func openDirectTCPIP(
        host: String,
        port: Int,
        configure: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        let handler = handler
        let target = SSHChannelType.DirectTCPIP(
            targetHost: host,
            targetPort: port,
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        )
        channel.eventLoop.execute {
            handler.withIsolatedValue { sshHandler in
                sshHandler.createChannel(promise, channelType: .directTCPIP(target)) { child, _ in
                    child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                        child.pipeline.addHandler(SSHDataToByteBufferCodec())
                    }.flatMap {
                        configure(child)
                    }
                }
            }
        }
        do {
            return try await promise.futureResult.get()
        } catch {
            throw Self.classifyChannelFailure(error, lastOffered: credentialChain.mostRecentlyOffered)
        }
    }

    /// Takes ownership of the connection this one is carried through (D-047).
    public func adopt(carrier: SSHConnection) {
        carriers.append(carrier)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        try? await channel.close().get()
        // Innermost first: the outer connections are what the inner ones travel through,
        // and closing a carrier before the thing it carries just drops the latter.
        let carriers = carriers
        self.carriers = []
        for carrier in carriers.reversed() {
            await carrier.close()
        }
        log.info("SSH connection closed")
    }

    /// Whether this connection can still carry a channel.
    ///
    /// Asked by the pool before handing one out (D-054): a transport whose channel has gone
    /// is worse than none, because every later caller would be given something that cannot
    /// carry anything and would fail at the first channel open rather than at connect time.
    public var isUsable: Bool { !closed && channel.isActive }

    /// The credential that was most recently offered, so a failed authentication can
    /// tell the user *which* credential the server rejected.
    public var lastOfferedCredential: SSHCredential? { credentialChain.mostRecentlyOffered }

    // MARK: - Internals

    internal func createSessionChannel() async throws -> Channel {
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        let handler = handler
        channel.eventLoop.execute {
            handler.withIsolatedValue { sshHandler in
                sshHandler.createChannel(promise, channelType: .session) { child, _ in
                    child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                }
            }
        }
        do {
            return try await promise.futureResult.get()
        } catch {
            throw Self.classifyChannelFailure(error, lastOffered: credentialChain.mostRecentlyOffered)
        }
    }

    internal static func attachStream(to child: Channel) async throws -> AsyncStream<SSHChannelEvent> {
        let (stream, continuation) = AsyncStream<SSHChannelEvent>.makeStream(bufferingPolicy: .unbounded)
        let handler = SSHChannelDataHandler(continuation: continuation)
        try await child.pipeline.addHandler(handler).get()
        return stream
    }

    internal static func request(
        on child: Channel,
        event: some Sendable,
        failureCategory: STErrorCategory,
        failureMessage: String
    ) async throws {
        let promise = child.eventLoop.makePromise(of: Void.self)
        child.triggerUserOutboundEvent(event, promise: promise)
        do {
            try await promise.futureResult.get()
        } catch {
            throw STError(
                category: failureCategory,
                message: failureMessage,
                recoverySuggestion: String(localized: "Check the server's sshd configuration, then try again.", bundle: .module),
                underlyingDescription: String(describing: error)
            )
        }
    }

    static func classifyChannelFailure(_ error: any Error, lastOffered: SSHCredential?) -> STError {
        if let sshError = error as? NIOSSHError {
            let description = String(describing: sshError)
            if description.contains("authenticationFailed") || description.contains("allAuthenticationOptionsFailed") {
                // Each sentence is its own catalog entry, joined here. Interpolating an
                // already-translated sentence into another one would give the translator a
                // bare `%@` they cannot place, and force a key whose leading space any
                // trimming tool would silently eat.
                var message = String(localized: "The server rejected every credential offered.", bundle: .module)
                if let lastOffered {
                    message += " " + String(
                        localized: "The last credential tried was a \(lastOffered.displayName).",
                        bundle: .module
                    )
                }
                return STError(
                    category: .sshAuthentication,
                    message: message,
                    recoverySuggestion: String(localized: "Check the username, and that the key is in the server's authorized_keys or that the password is correct.", bundle: .module),
                    underlyingDescription: description
                )
            }
            return STError(
                category: .sshTransport,
                message: String(localized: "The SSH handshake failed.", bundle: .module),
                recoverySuggestion: String(localized: "The server may require an algorithm this app does not support. See the compatibility notes in the documentation.", bundle: .module),
                underlyingDescription: description
            )
        }
        if let stError = error as? STError { return stError }
        return STError(
            category: .sshTransport,
            message: String(localized: "The SSH session could not be established.", bundle: .module),
            underlyingDescription: String(describing: error)
        )
    }
}

public struct SSHCommandResult: Sendable {
    public let standardOutput: Data
    public let standardError: Data
    public let exitStatus: Int?

    public var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }
    public var standardErrorText: String { String(decoding: standardError, as: UTF8.self) }
}

/// Holds a value that is only ever touched on one event loop.
///
/// NIOSSH's handler is explicitly not `Sendable`, and correctly so: it is a mutable
/// state machine owned by its channel. This box makes that ownership rule explicit and
/// checkable — every access asserts it is running on the owning loop — rather than
/// silencing the compiler and hoping.
final class EventLoopIsolated<Value>: @unchecked Sendable {
    private let value: Value
    let eventLoop: EventLoop

    init(_ value: Value, eventLoop: EventLoop) {
        self.value = value
        self.eventLoop = eventLoop
    }

    func withIsolatedValue<T>(_ body: (Value) throws -> T) rethrows -> T {
        eventLoop.assertInEventLoop()
        return try body(value)
    }
}

/// Events emitted by an SSH channel.
public enum SSHChannelEvent: Sendable {
    case output(Data)
    case errorOutput(Data)
    case exit(Int)
    case closed
}

/// Turns a handshake failure into the specific, actionable error the user sees.
///
/// The mapping matters: "the host key changed" and "your password is wrong" demand
/// completely different responses, and collapsing them into "connection failed" is how
/// a client trains people to click through a real machine-in-the-middle warning.
func classifyHandshakeFailure(
    _ error: any Error,
    lastOffered: SSHCredential?,
    identity: KnownHostIdentity
) -> STError {
    // The host key verifier's own error is already precise; never bury it.
    if let stError = error as? STError { return stError }

    // Someone dismissed the server's questions. That is a choice, not a failure, and it
    // must not be reported as the server rejecting a credential.
    if let cancelled = error as? SSHKeyboardInteractiveCancelled { return cancelled.stError }

    if let authError = error as? SSHAuthenticationError {
        let attempted = authError.attempted.isEmpty
            ? String(localized: "No credential was accepted for an attempt.", bundle: .module)
            : String(localized: "Tried: \(authError.attempted.joined(separator: ", ")).", bundle: .module)
        return STError(
            category: .sshAuthentication,
            message: String(localized: "The server rejected every credential offered.", bundle: .module)
                + " " + attempted,
            recoverySuggestion: String(localized: "Check the username, and that the key is in the server's authorized_keys or that the password is correct.", bundle: .module),
            underlyingDescription: "user authentication exhausted for \(identity.storageKey)"
        )
    }

    if error is SSHHandshakeIncomplete {
        // Network, not transport. Nothing SSH promises was broken: there was no key
        // exchange failure, no MAC failure and no host key mismatch — the connection
        // simply went away. The distinction is not academic, because the category is what
        // decides whether the app may retry on its own, and this is the single most
        // common way a mobile connection dies: a hand-off between Wi-Fi and cellular, a
        // load balancer with no healthy backend, a tunnel whose origin is restarting.
        // Grouping it with cryptographic failures would mean never retrying any of them.
        return STError(
            category: .network,
            message: String(localized: "The server closed the connection before the SSH session was established.", bundle: .module),
            recoverySuggestion: String(localized: "Check that the port really is an SSH server, and that the server's log does not show a rejected connection.", bundle: .module)
        )
    }

    if let sshError = error as? NIOSSHError {
        let description = String(describing: sshError)
        if description.contains("keyExchangeNegotiationFailure") {
            return STError(
                category: .sshTransport,
                message: String(localized: "This server and ApexTerminal share no supported key exchange or host key algorithm.", bundle: .module),
                recoverySuggestion: String(localized: "The server may only offer RSA host keys. See the algorithm compatibility notes in the documentation.", bundle: .module),
                underlyingDescription: description
            )
        }
        return STError(
            category: .sshTransport,
            message: String(localized: "The SSH handshake failed.", bundle: .module),
            recoverySuggestion: String(localized: "The server may require an algorithm this app does not support. See the compatibility notes in the documentation.", bundle: .module),
            underlyingDescription: description
        )
    }

    return STError(
        category: .sshTransport,
        message: String(localized: "The SSH session could not be established.", bundle: .module),
        underlyingDescription: String(describing: error)
    )
}

/// Turns SSH channel data into plain bytes and back, so ordinary NIO handlers — a VNC
/// client, say — can sit on a `direct-tcpip` channel as if it were a socket.
final class SSHDataToByteBufferCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = channelData.data, channelData.type == .channel else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}
