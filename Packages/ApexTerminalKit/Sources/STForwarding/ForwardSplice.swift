import NIOCore
import STSSH

/// Joins an accepted connection to a channel through the SSH connection.
///
/// The order matters more than it looks. Each half of the glue is installed *before* its
/// channel can deliver anything — through the channel initialiser where there is one, and
/// through ``HoldingHandler`` where the channel is already alive. What a service says
/// first is usually the part that matters: an SMTP banner, an IMAP greeting, the version
/// string of an SSH server behind the forward. A splice assembled after the fact loses it.
enum ForwardSplice {
    /// Counts one connection for the pair and stops counting when either end goes.
    /// Asks both channels for their first read, now that each has somewhere to put it.
    ///
    /// The glue parks a read it cannot satisfy — the other half not being in place yet —
    /// and a channel that was reading before the splice may have had its request parked
    /// that way. `autoRead` will not re-issue one on its own, because it only does so
    /// after a read completes, and none can. So the splice asks once, explicitly.
    static func activate(_ first: Channel, _ second: Channel) {
        first.read()
        second.read()
    }

    static func account(_ channel: Channel, counter: TrafficCounter) {
        counter.connectionOpened()
        // One decrement per connection, however it ends: whichever side closes first takes
        // the other with it through the glue, so counting both would double.
        channel.closeFuture.whenComplete { _ in counter.connectionClosed() }
    }
}
