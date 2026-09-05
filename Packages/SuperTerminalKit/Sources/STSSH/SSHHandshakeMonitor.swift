import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH
import STCore

/// Observes the SSH handshake so that `connect` can resolve as soon as the outcome is
/// known, with the *specific* reason it failed.
///
/// Without this, two things go wrong. First, failures only surface when the caller
/// later tries to open a channel, by which point the original error — "the host key
/// changed", "the server rejected your key" — has been replaced by a generic closed-
/// channel error. Second, a connection that dies during key exchange looks identical
/// to one that is merely slow. Recording the first error and completing on
/// `UserAuthSuccessEvent` fixes both.
final class SSHHandshakeMonitor: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    typealias InboundOut = Any

    private let readyPromise: EventLoopPromise<Void>
    private let firstError = NIOLockedValueBox<(any Error)?>(nil)
    private var completed = false
    private let log: STLogger

    init(readyPromise: EventLoopPromise<Void>, log: STLogger) {
        self.readyPromise = readyPromise
        self.log = log
    }

    /// The first error seen on this channel, which is the one that explains why the
    /// connection failed. Later errors are consequences.
    var recordedError: (any Error)? { firstError.withLockedValue { $0 } }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !completed {
            completed = true
            log.info("SSH authentication succeeded")
            readyPromise.succeed(())
        }
        if let banner = event as? NIOUserAuthBannerEvent {
            // Banners are attacker-influenced text from an unauthenticated peer; they
            // are recorded for diagnostics but never rendered as trusted UI.
            log.debug("server sent an authentication banner", ["length": "\(banner.message.count)"])
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        firstError.withLockedValue { stored in
            if stored == nil { stored = error }
        }
        // Any error before authentication completes is fatal, and waiting for the
        // channel to close would turn a precise failure into a timeout: NIOSSH does not
        // close the connection when the credential chain is exhausted, so the server's
        // LoginGraceTime — two minutes — would be the only thing ending the attempt.
        if !completed {
            completed = true
            readyPromise.fail(error)
            context.close(promise: nil)
        }
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        channelClosedBeforeReady()
        context.fireChannelInactive()
    }

    /// Settles the handshake as failed if the channel has gone before it finished.
    ///
    /// Called both from `channelInactive` and from the channel's own close future,
    /// because a peer that closes the moment it accepts can beat this handler into the
    /// pipeline — in which case `channelInactive` is never delivered here at all.
    /// Both paths run on the channel's event loop, which is what makes the flag safe.
    func channelClosedBeforeReady() {
        guard !completed else { return }
        completed = true
        readyPromise.fail(recordedError ?? SSHHandshakeIncomplete())
    }
}

/// The connection closed before authentication finished and no more specific error was
/// reported — typically a server that dropped the connection, or a middlebox.
struct SSHHandshakeIncomplete: Error, Sendable {}
