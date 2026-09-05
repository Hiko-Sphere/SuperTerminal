import Foundation
import STCore
@testable import STSSH
import Testing

/// The category an error carries is not a label — it decides what the app does next, and
/// in particular whether it may retry on its own. These pin the ones where that matters.
@Suite("SSH error categories")
struct SSHErrorCategoryTests {
    @Test("A connection that dies before the handshake finishes is a network failure")
    func handshakeIncompleteIsNetwork() {
        let error = classifyHandshakeFailure(
            SSHHandshakeIncomplete(),
            lastOffered: nil,
            identity: KnownHostIdentity(host: "example.invalid", port: 22)
        )
        // It was previously grouped with key exchange and MAC failures, which meant the
        // single most common way a mobile connection dies — a hand-off, a tunnel whose
        // origin is restarting — was never retried.
        #expect(error.category == .network)
    }
}
