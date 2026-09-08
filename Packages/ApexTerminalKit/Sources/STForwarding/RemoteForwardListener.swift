import NIOCore
import NIOSSH
import NIOTransportServices
import STCore
import STSSH

/// A port the *server* listens on, whose connections come back here (`ssh -R`).
///
/// The direction is the interesting part: the server accepts, and opens a channel to this
/// device for each connection. So the server has to be willing — `AllowTcpForwarding` — and
/// for anything but a loopback bind it also needs `GatewayPorts`, which most sshd
/// configurations leave off. A refusal says which of those to look at rather than reporting
/// a bare failure.
actor RemoteForwardListener {
    private let rule: PortForward
    private let connection: SSHConnection
    private let counter: TrafficCounter
    private let group: NIOTSEventLoopGroup
    private let log: STLogger
    private var boundPort: Int?

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
        self.log = log.child(subsystem: "forwarding.remote")
    }

    func start() async throws -> Int {
        let rule = rule
        let counter = counter
        let group = group
        let log = log
        let bound = try await connection.startRemoteForward(
            bindHost: rule.remoteBindHost,
            port: rule.listenPort
        ) { channel, forwarded in
            // Called on the channel's own event loop, before it is active, so this is the
            // last moment at which a handler can be in place for whatever the server
            // sends first. The local connection cannot be made here — that is asynchronous
            // — so the bytes are held until it is.
            try? channel.pipeline.syncOperations.addHandler(HoldingHandler())
            Task {
                await Self.accept(
                    channel,
                    from: forwarded,
                    rule: rule,
                    counter: counter,
                    group: group,
                    log: log
                )
            }
        }
        boundPort = bound
        return bound
    }

    func stop() async {
        guard let boundPort else { return }
        self.boundPort = nil
        try? await connection.cancelRemoteForward(bindHost: rule.remoteBindHost, port: boundPort)
    }

    private static func accept(
        _ fromServer: Channel,
        from forwarded: SSHChannelType.ForwardedTCPIP,
        rule: PortForward,
        counter: TrafficCounter,
        group: NIOTSEventLoopGroup,
        log: STLogger
    ) async {
        do {
            let (serverSide, localSide) = GlueHandler.pair(counter: counter)
            // On the same loop as the channel it will be glued to; see the listener.
            let local = try await NIOTSConnectionBootstrap(group: fromServer.eventLoop)
                .channelInitializer { channel in
                    channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        .flatMap { channel.pipeline.addHandler(localSide) }
                }
                .connect(host: rule.targetHost, port: rule.targetPort)
                .get()
            try await fromServer.pipeline.addHandler(serverSide).get()
            ForwardSplice.account(fromServer, counter: counter)
            _ = local
            try await fromServer.releaseHeldReads().get()
            ForwardSplice.activate(fromServer, local)
            log.debug("spliced a forwarded connection", ["target": "\(rule.targetHost):\(rule.targetPort)"])
        } catch {
            // Nothing to tell the far end: it is a plain TCP peer that connected to the
            // server, and the only honest answer is to close.
            log.info("could not deliver a forwarded connection", [
                "target": "\(rule.targetHost):\(rule.targetPort)",
                "error": String(describing: error),
            ])
            try? await fromServer.close().get()
        }
    }
}
