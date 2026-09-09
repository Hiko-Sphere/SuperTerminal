import Foundation
import Testing
import STForwarding
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

/// Editing a connection must not quietly discard what the editor does not show (D-047).
@Suite("Editing a connection")
struct HostEditingTests {
    private var fields: HostEditorFields {
        HostEditorFields(
            name: "Renamed",
            hostname: "new.example",
            port: 2222,
            username: "root",
            transport: .directTCP,
            credentials: [],
            folder: nil,
            terminalType: "xterm-256color",
            accessAuthentication: nil,
            platformOverride: nil,
            showsInFiles: false,
            jumpHosts: [],
            forwardsAgent: false,
            usesTmux: false,
            tmuxSessionName: ""
        )
    }

    @Test("Agent forwarding cannot be saved on a connection with no key to offer")
    func agentForwardingNeedsAKey() {
        let host = Host(name: "Old", hostname: "old.example", username: "user")
        var wanted = fields
        wanted.forwardsAgent = true

        // No private key among the credentials: the toggle is disabled in that state, and
        // a record saved with it on would promise something the connection cannot do.
        #expect(host.applying(wanted).forwardsAgent == nil)

        wanted.credentials = [.privateKey(id: UUID())]
        #expect(host.applying(wanted).forwardsAgent == true)
        #expect(host.applying(wanted).isForwardingAgent)
    }

    @Test("An edit keeps everything the editor does not show")
    func editingPreservesUnseenFields() {
        var host = Host(name: "Old", hostname: "old.example", username: "user")
        host.portForwards = [PortForward(kind: .local, listenPort: 8080, targetHost: "db", targetPort: 5432)]
        host.tags = ["work"]
        host.environment = ["LANG": "en_GB.UTF-8"]
        host.detectedPlatform = .linux
        host.lastConnected = Date(timeIntervalSince1970: 1_700_000_000)
        host.themeID = "solarized"

        let edited = host.applying(fields)

        // The fields the editor showed changed…
        #expect(edited.name == "Renamed")
        #expect(edited.hostname == "new.example")
        #expect(edited.port == 2222)
        // …and everything it did not is exactly as it was. This is the regression: saving
        // an edit used to erase the port forwards.
        #expect(edited.id == host.id)
        #expect(edited.portForwards == host.portForwards)
        #expect(edited.tags == host.tags)
        #expect(edited.environment == host.environment)
        #expect(edited.detectedPlatform == host.detectedPlatform)
        #expect(edited.lastConnected == host.lastConnected)
        #expect(edited.themeID == host.themeID)
    }

    @Test("An empty jump chain is stored as nothing rather than an empty list")
    func emptyChainIsNil() {
        var host = Host(name: "H", hostname: "h", username: "u")
        host.jumpHosts = [UUID()]
        #expect(host.applying(fields).jumpHosts == nil)

        var withChain = fields
        let hop = UUID()
        withChain.jumpHosts = [hop]
        #expect(host.applying(withChain).jumpHosts == [hop])
    }
}
