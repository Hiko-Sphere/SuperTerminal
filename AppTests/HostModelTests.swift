import Foundation
import Testing
@testable import ApexTerminal

@Suite("Host model")
struct HostModelTests {
    @Test("A Cloudflare host is remembered against port 443, not the origin's SSH port")
    func cloudflareIdentityUsesEdgePort() {
        // For a Cloudflare connection the port is the edge's, not the origin's: the client
        // speaks TLS to the edge and the tunnel's own ingress decides where SSH is, which
        // nothing typed here can change. Blank means 443, and the identity records the
        // port actually contacted — filing the key under an endpoint never reached would
        // make the same server look like two.
        let onTheDefaultPort = Host(
            name: "Bastion",
            hostname: "ssh.example.com",
            username: "ops",
            transport: .cloudflare(jumpDestination: "internal:22"),
            credentials: [.password]
        )
        #expect(Host.defaultPort(for: onTheDefaultPort.transport) == 443)
        #expect(onTheDefaultPort.port == 443, "a Cloudflare host built without a port takes the edge's, not SSH's")
        #expect(onTheDefaultPort.knownHostIdentity.port == 443)
        #expect(onTheDefaultPort.knownHostIdentity.jumpDestination == "internal:22")

        // Cloudflare also publishes on 2053, 2083, 2087, 2096 and 8443 (D-024).
        var onAnAlternatePort = onTheDefaultPort
        onAnAlternatePort.port = 8443
        #expect(onAnAlternatePort.knownHostIdentity.port == 8443)

        // A record written before the port field existed carried the SSH default on a
        // Cloudflare host, where it meant nothing; loading rewrites it to the edge's.
        var legacy = onTheDefaultPort
        legacy.port = 22
        #expect(HostStore.migrated(legacy).port == 443)
        #expect(HostStore.migrated(onAnAlternatePort).port == 8443, "a port the user chose is left alone")
    }

    @Test("Validation names every problem rather than only the first")
    func validationIsExhaustive() {
        let host = Host(name: "", hostname: "", port: 0, username: "", credentials: [])
        // A name, an address and a usable port are the whole requirement (D-024).
        #expect(host.validationProblems.count == 3)
        #expect(host.validationProblems.contains { $0.contains("name") })
        #expect(host.validationProblems.contains { $0.contains("hostname") })
        #expect(host.validationProblems.contains { $0.contains("Port") })
    }

    @Test("A connection with no user name and no credential is allowed: both are asked for when it opens")
    func blankUserNameAndCredentialsValidate() {
        let host = Host(name: "Anything", hostname: "build.example.com", username: "", credentials: [])
        #expect(host.port == 22, "a direct connection built without a port takes SSH's")
        #expect(host.validationProblems.isEmpty)
        #expect(host.subtitle == "build.example.com", "no user name, and 22 is the default, so neither is shown")
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
