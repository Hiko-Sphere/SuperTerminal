import Foundation
import Testing
@testable import SuperTerminal

@Suite("Host model")
struct HostModelTests {
    @Test("A Cloudflare host is remembered against port 443, not the origin's SSH port")
    func cloudflareIdentityUsesEdgePort() {
        let host = Host(
            name: "Bastion",
            hostname: "ssh.example.com",
            port: 2222,
            username: "ops",
            transport: .cloudflare(jumpDestination: "internal:22"),
            credentials: [.password]
        )
        // The client never speaks SSH to port 2222; it speaks TLS to the edge on 443 and
        // the tunnel reaches the origin. Recording the origin port would file the host
        // key under an endpoint that was never contacted.
        #expect(host.knownHostIdentity.port == 443)
        #expect(host.knownHostIdentity.jumpDestination == "internal:22")
    }

    @Test("Validation names every problem rather than only the first")
    func validationIsExhaustive() {
        let host = Host(name: "", hostname: "", port: 0, username: "", credentials: [])
        #expect(host.validationProblems.count == 5)
    }

    @Test("A complete host validates")
    func completeHostValidates() {
        let host = Host(
            name: "Web",
            hostname: "web.example.com",
            username: "deploy",
            credentials: [.privateKey(id: UUID())]
        )
        #expect(host.validationProblems.isEmpty)
    }
}
