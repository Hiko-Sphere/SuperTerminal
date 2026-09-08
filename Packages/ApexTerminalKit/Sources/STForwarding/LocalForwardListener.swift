#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import NIOCore
import NIOTransportServices
import STCore
import STSSH

/// A port on this device that the server answers for (`ssh -L`), and the SOCKS5 variant
/// where each client picks its own destination (`ssh -D`).
///
/// It binds `127.0.0.1` and nothing else. A phone that listened on its Wi-Fi address would
/// be offering a tunnel into the server to everything on the network it happens to have
/// joined — a coffee shop, a hotel, a conference — and the person who set up the forward
/// would have no way to know. Anything wider than loopback is a decision that deserves to
/// be asked for explicitly, and nothing here asks.
actor LocalForwardListener {
    private let rule: PortForward
    private let connection: SSHConnection
    private let counter: TrafficCounter
    private let group: NIOTSEventLoopGroup
    private let log: STLogger
    private var channel: Channel?

    init(
        rule: PortForward,
        connection: SSHConnection,
        counter: TrafficCounter,
        group: NIOTSEventLoopGroup,
        log: STLogger
    ) {
        self.rule = rule
        self.connection = connection
        self.counter = counter
        self.group = group
        self.log = log.child(subsystem: "forwarding.local")
    }

    /// Binds the port, and reports the one that was bound.
    func start() async throws -> Int {
        let rule = rule
        let connection = connection
        let counter = counter
        let log = log
        // No backlog option: Network.framework's listener does not have one, and asking
        // for it traps rather than being ignored.
        //
        // Accepted connections land on the SSH connection's own event loop. That is not an
        // optimisation, it is a requirement: each forwarded connection is two channels
        // glued together and the glue reads the other side's state directly, which NIO
        // only permits within one loop. It costs nothing either — every byte has to pass
        // through the single SSH connection regardless.
        let bootstrap = NIOTSListenerBootstrap(group: group, childGroup: connection.eventLoop)
            .childChannelInitializer { child in
                // Reads off until the far end exists; see `ForwardSplice`.
                child.setOption(ChannelOptions.autoRead, value: false)
                    .flatMap { child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true) }
                    .map {
                        Task {
                            await Self.accept(
                                child, rule: rule, connection: connection, counter: counter, log: log
                            )
                        }
                    }
            }

        do {
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: rule.listenPort).get()
            self.channel = channel
            let bound = channel.localAddress?.port ?? rule.listenPort
            log.info("listening", ["port": "\(bound)", "kind": rule.kind.rawValue])
            return bound
        } catch {
            throw Self.bindFailure(error, port: rule.listenPort)
        }
    }

    func stop() async {
        let channel = channel
        self.channel = nil
        try? await channel?.close().get()
    }

    // MARK: - One accepted connection

    private static func accept(
        _ client: Channel,
        rule: PortForward,
        connection: SSHConnection,
        counter: TrafficCounter,
        log: STLogger
    ) async {
        do {
            let destination: (host: String, port: Int)
            switch rule.kind {
            case .dynamic:
                // The SOCKS client says where it wants to go, and is told whether it got
                // there — before the destination is even attempted, the greeting has to
                // be answered, so this reads from the client first.
                destination = try await SOCKS5Negotiation.destination(on: client)
            default:
                destination = (rule.targetHost, rule.targetPort)
            }

            // The pair exists before either channel can deliver anything: this half goes
            // into the accepted connection, which still has reads switched off, and the
            // other goes into the SSH channel's initialiser, before it activates.
            let (clientSide, remoteSide) = GlueHandler.pair(counter: counter)
            try await client.pipeline.addHandler(clientSide).get()

            let remote: Channel
            do {
                remote = try await connection.openDirectTCPIP(host: destination.host, port: destination.port) { channel in
                    channel.pipeline.addHandler(remoteSide)
                }
            } catch {
                if rule.kind == .dynamic {
                    // A SOCKS client that is never answered waits forever. Telling it the
                    // truth lets a browser show "connection refused" instead of hanging.
                    try? await SOCKS5Negotiation.replyFailure(on: client)
                }
                throw error
            }

            ForwardSplice.account(client, counter: counter)
            if rule.kind == .dynamic {
                try await SOCKS5Negotiation.replySuccess(on: client)
            }
            // Only now does the accepted connection start reading. Everything downstream
            // of it already exists.
            try await client.setOption(ChannelOptions.autoRead, value: true).get()
            ForwardSplice.activate(client, remote)
        } catch {
            log.info("forwarded connection failed", ["error": String(describing: error)])
            try? await client.close().get()
        }
    }

    /// Turns a bind failure into something the user can act on.
    ///
    /// "Address already in use" is by far the most common, and it is worth naming: the
    /// port is usually held by an earlier forward, or by another app.
    static func bindFailure(_ error: Error, port: Int) -> STError {
        // Network.framework and the POSIX stack report this differently, and which one
        // is underneath depends on the bootstrap; both are checked rather than assuming.
        let inUse: Bool
        if let posix = error as? IOError {
            inUse = posix.errnoCode == EADDRINUSE
        } else {
            let described = String(describing: error)
            inUse = described.contains("Address already in use") || described.contains("48")
        }

        // Interpolated as text, not as a number. A port is an identifier: formatted as an
        // integer it comes out as "49,870" in English and worse elsewhere, and a port with
        // a thousands separator in it is not a port anyone can type back.
        let portText = String(port)
        if inUse {
            return STError(
                category: .configuration,
                message: String(localized: "Port \(portText) on this device is already in use.", bundle: .module),
                recoverySuggestion: String(localized: "Stop whatever is using it, or give this rule a different port.", bundle: .module)
            )
        }
        if port < 1024 {
            return STError(
                category: .configuration,
                message: String(localized: "This device will not let the app listen on port \(portText).", bundle: .module),
                recoverySuggestion: String(localized: "Ports below 1024 are reserved. Use a port of 1024 or above.", bundle: .module),
                underlyingDescription: String(describing: error)
            )
        }
        return STError(
            category: .configuration,
            message: String(localized: "Could not listen on port \(portText).", bundle: .module),
            underlyingDescription: String(describing: error)
        )
    }
}
