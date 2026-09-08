import Foundation
import NIOCore

/// Ports for the listeners these tests bind.
///
/// Deliberately *not* the ephemeral range. `OpenSSHTestServer` chooses its port by binding
/// zero, reading the number and letting go — so between letting go and sshd binding, the
/// kernel is free to hand that number to somebody else. This suite binds more listeners
/// than any other, and when one of them won that race the harness's sshd failed to bind,
/// some unrelated suite connected to a forwarding listener instead, and reported an SSH
/// handshake that timed out thirty seconds later. Six full runs, four failures, never the
/// same test twice.
///
/// The kernel assigns ephemeral ports from 49152 upwards on this platform. Choosing from
/// well below that means these listeners cannot collide with anything the kernel hands
/// out, and the race is not merely less likely but gone.
enum TestPorts {
    static let range = 21000 ..< 30000

    /// A port in the safe range, retried until something binds.
    static func bind(_ attempt: (Int) async throws -> Void) async throws -> Int {
        var lastError: Error?
        for _ in 0 ..< 40 {
            let port = Int.random(in: range)
            do {
                try await attempt(port)
                return port
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NoPortAvailable()
    }

    struct NoPortAvailable: Error, CustomStringConvertible {
        var description: String { "no port in \(TestPorts.range) could be bound" }
    }
}
