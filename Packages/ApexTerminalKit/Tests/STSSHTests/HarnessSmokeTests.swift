import Foundation
import STTestSupport
import Testing

@Suite("Test harness smoke")
struct HarnessSmokeTests {
    @Test("The OpenSSH test server starts and reports fixtures")
    func serverStarts() throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }
        #expect(server.fixtures.port > 0)
        #expect(server.fixtures.clientPrivateKeyPEM.contains("OPENSSH PRIVATE KEY"))
        #expect(server.hostKeyOpenSSHLine.hasPrefix("ssh-ed25519 "))
    }
}
