import Foundation
import NIOCore
import NIOSSH
import STCore
import STSFTP

/// An SFTP channel over SSH (D-041).
///
/// The `sftp` subsystem is an ordinary session channel with a subsystem request instead of
/// a shell request. Everything after that is the file-transfer protocol, which `STSFTP`
/// speaks and this only carries.
public final class SFTPChannel: SFTPTransport, @unchecked Sendable {
    private let channel: Channel
    private let log: STLogger

    init(channel: Channel, log: STLogger) {
        self.channel = channel
        self.log = log
    }

    public func send(_ data: Data) async throws {
        guard channel.isActive else {
            throw STError(
                category: .sshChannel,
                message: String(localized: "The file connection was closed.", bundle: .module),
                recoverySuggestion: String(localized: "Open the files again to reconnect.", bundle: .module)
            )
        }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
    }

    public func close() async {
        try? await channel.close().get()
    }
}

public extension SSHConnection {
    /// Opens the `sftp` subsystem and hands back a client that has already agreed a
    /// version with the server.
    func openSFTP() async throws -> SFTPClient {
        let child = try await createSessionChannel()
        let stream = try await Self.attachStream(to: child)
        do {
            try await Self.request(
                on: child,
                event: SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true),
                failureCategory: .sshChannel,
                failureMessage: String(localized: "The server refused to start file transfer. It may not have the SFTP subsystem enabled.", bundle: .module)
            )
        } catch {
            try? await child.close().get()
            throw error
        }

        let client = SFTPClient(transport: SFTPChannel(channel: child, log: log), log: log)
        // Feeding the client from the channel's stream, rather than the client pulling,
        // keeps the ordering the protocol depends on: replies are matched by id, but the
        // bytes carrying them still have to arrive in order.
        Task {
            for await event in stream {
                switch event {
                case let .output(data): await client.receive(data)
                // stderr from a subsystem is the server complaining, not file data, and
                // an exit ends the channel — neither is a packet.
                default: break
                }
            }
            await client.transportClosed()
        }
        try await client.start()
        log.info("sftp channel opened")
        return client
    }
}
