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

    public init(
        username: String,
        credentials: [SSHCredential],
        knownHostIdentity: KnownHostIdentity,
        keepAliveInterval: TimeAmount = .seconds(30),
        handshakeTimeout: TimeAmount = .seconds(30)
    ) {
        self.username = username
        self.credentials = credentials
        self.knownHostIdentity = knownHostIdentity
        self.keepAliveInterval = keepAliveInterval
        self.handshakeTimeout = handshakeTimeout
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
    private let log: STLogger
    private var closed = false

    private init(
        channel: Channel,
        handler: EventLoopIsolated<NIOSSHHandler>,
        credentialChain: SSHCredentialChain,
        log: STLogger
    ) {
        self.channel = channel
        self.handler = handler
        self.credentialChain = credentialChain
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
            log: log
        )
        // The handler is constructed *inside* the event loop and never leaves it:
        // NIOSSHHandler is a mutable state machine that is deliberately not Sendable,
        // so the only safe place to build and install it is the loop that owns it.
        let readyPromise = channel.eventLoop.makePromise(of: Void.self)
        let monitor = SSHHandshakeMonitor(readyPromise: readyPromise, log: log)

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
                    inboundChildChannelInitializer: nil
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
            try? await channel.close().get()
            throw STError(
                category: .sshTransport,
                message: "Could not start the SSH session.",
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
                message: "The SSH handshake did not complete in time.",
                recoverySuggestion: "Check that the server is reachable and really is an SSH server, then try again."
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
        Constants.bundledTransportProtectionSchemesErased + [AES256CTRSHA256ETMTransportProtection.self]
    }

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
                failureMessage: "The server refused to allocate a terminal."
            )
            for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
                // Servers commonly refuse env requests they have not allowlisted;
                // that is not fatal, so failures are logged and the session continues.
                try? await Self.request(
                    on: child,
                    event: SSHChannelRequestEvent.EnvironmentRequest(wantReply: true, name: name, value: value),
                    failureCategory: .sshChannel,
                    failureMessage: "The server refused an environment variable."
                )
            }
            try await Self.request(
                on: child,
                event: SSHChannelRequestEvent.ShellRequest(wantReply: true),
                failureCategory: .sshChannel,
                failureMessage: "The server refused to start a shell."
            )
        } catch {
            try? await child.close().get()
            throw error
        }

        log.info("interactive shell opened", ["cols": "\(size.columns)", "rows": "\(size.rows)"])
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
            failureMessage: "The server refused to run the command."
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

    public func close() async {
        guard !closed else { return }
        closed = true
        try? await channel.close().get()
        log.info("SSH connection closed")
    }

    /// The credential that was most recently offered, so a failed authentication can
    /// tell the user *which* credential the server rejected.
    public var lastOfferedCredential: SSHCredential? { credentialChain.mostRecentlyOffered }

    // MARK: - Internals

    private func createSessionChannel() async throws -> Channel {
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

    private static func attachStream(to child: Channel) async throws -> AsyncStream<SSHChannelEvent> {
        let (stream, continuation) = AsyncStream<SSHChannelEvent>.makeStream(bufferingPolicy: .unbounded)
        let handler = SSHChannelDataHandler(continuation: continuation)
        try await child.pipeline.addHandler(handler).get()
        return stream
    }

    private static func request(
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
                recoverySuggestion: "Check the server's sshd configuration, then try again.",
                underlyingDescription: String(describing: error)
            )
        }
    }

    static func classifyChannelFailure(_ error: any Error, lastOffered: SSHCredential?) -> STError {
        if let sshError = error as? NIOSSHError {
            let description = String(describing: sshError)
            if description.contains("authenticationFailed") || description.contains("allAuthenticationOptionsFailed") {
                let attempted = lastOffered.map { " The last credential tried was a \($0.displayKind)." } ?? ""
                return STError(
                    category: .sshAuthentication,
                    message: "The server rejected every credential offered.\(attempted)",
                    recoverySuggestion: "Check the username, and that the key is in the server's authorized_keys or that the password is correct.",
                    underlyingDescription: description
                )
            }
            return STError(
                category: .sshTransport,
                message: "The SSH handshake failed.",
                recoverySuggestion: "The server may require an algorithm this app does not support. See the compatibility notes in the documentation.",
                underlyingDescription: description
            )
        }
        if let stError = error as? STError { return stError }
        return STError(
            category: .sshTransport,
            message: "The SSH session could not be established.",
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

    if let authError = error as? SSHAuthenticationError {
        let attempted = authError.attempted.isEmpty
            ? "No credential was accepted for an attempt."
            : "Tried: \(authError.attempted.joined(separator: ", "))."
        return STError(
            category: .sshAuthentication,
            message: "The server rejected every credential offered. \(attempted)",
            recoverySuggestion: "Check the username, and that the key is in the server's authorized_keys or that the password is correct.",
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
            message: "The server closed the connection before the SSH session was established.",
            recoverySuggestion: "Check that the port really is an SSH server, and that the server's log does not show a rejected connection."
        )
    }

    if let sshError = error as? NIOSSHError {
        let description = String(describing: sshError)
        if description.contains("keyExchangeNegotiationFailure") {
            return STError(
                category: .sshTransport,
                message: "This server and SuperTerminal share no supported key exchange or host key algorithm.",
                recoverySuggestion: "The server may only offer RSA host keys. See the algorithm compatibility notes in the documentation.",
                underlyingDescription: description
            )
        }
        return STError(
            category: .sshTransport,
            message: "The SSH handshake failed.",
            recoverySuggestion: "The server may require an algorithm this app does not support. See the compatibility notes in the documentation.",
            underlyingDescription: description
        )
    }

    return STError(
        category: .sshTransport,
        message: "The SSH session could not be established.",
        underlyingDescription: String(describing: error)
    )
}
