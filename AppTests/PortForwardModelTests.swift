import Foundation
import STForwarding
import Testing

@testable import ApexTerminal

/// What a forwarding rule will and will not accept (D-045).
///
/// The editor refuses to save a rule these tests reject, so this is where the reasons are
/// pinned: finding out at connection time, three screens away, is how a typo becomes a
/// mystery.
@Suite("Port forward rules")
struct PortForwardModelTests {
    @Test("A local forward needs a real port on this device and a destination")
    func localValidation() {
        #expect(PortForward(kind: .local, listenPort: 8080, targetHost: "db", targetPort: 5432)
            .validationProblems.isEmpty)
        // Zero means "choose one for me", which only a server can do.
        #expect(!PortForward(kind: .local, listenPort: 0, targetHost: "db", targetPort: 5432)
            .validationProblems.isEmpty)
        #expect(!PortForward(kind: .local, listenPort: 8080, targetHost: "", targetPort: 5432)
            .validationProblems.isEmpty)
        #expect(!PortForward(kind: .local, listenPort: 8080, targetHost: "db", targetPort: 0)
            .validationProblems.isEmpty)
        #expect(!PortForward(kind: .local, listenPort: 70000, targetHost: "db", targetPort: 5432)
            .validationProblems.isEmpty)
    }

    @Test("A remote forward may ask the server to choose the port")
    func remoteAllowsZero() {
        #expect(PortForward(kind: .remote, listenPort: 0, targetHost: "127.0.0.1", targetPort: 3000)
            .validationProblems.isEmpty)
    }

    @Test("A dynamic forward has no destination to give")
    func dynamicNeedsNoDestination() {
        #expect(PortForward(kind: .dynamic, listenPort: 1080).validationProblems.isEmpty)
    }

    @Test("A rule with no name describes itself by its addresses")
    func summaries() {
        #expect(PortForward(kind: .local, listenPort: 8080, targetHost: "db.internal", targetPort: 5432)
            .displayName == "127.0.0.1:8080 → db.internal:5432")
        #expect(PortForward(kind: .dynamic, listenPort: 1080).displayName == "SOCKS5 127.0.0.1:1080")
        #expect(PortForward(name: "Postgres", kind: .local, listenPort: 8080, targetHost: "db", targetPort: 5432)
            .displayName == "Postgres")
        // A name of nothing but spaces is not a name.
        #expect(PortForward(name: "   ", kind: .dynamic, listenPort: 1080).displayName
            == "SOCKS5 127.0.0.1:1080")
    }

    @Test("Rules survive being saved with the connection")
    func rulesRoundTripOnTheHost() throws {
        var host = Host(name: "Box", hostname: "box.test", username: "root")
        host.portForwards = [
            PortForward(name: "db", kind: .local, listenPort: 5433, targetHost: "127.0.0.1", targetPort: 5432),
            PortForward(kind: .dynamic, listenPort: 1080, startsAutomatically: true),
        ]
        let decoded = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host))
        #expect(decoded.portForwards == host.portForwards)
    }

    @Test("A connection saved before forwarding existed still decodes")
    func olderRecordsStillDecode() throws {
        // The field is optional precisely so that this works; a synthesized decoder
        // throws on a missing key otherwise, and every saved connection would be lost.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","hostname":"old.test","port":22,"username":"root",
         "transport":{"directTCP":{}},"credentials":[],"tags":[],"terminalType":"xterm-256color",
         "environment":{}}
        """
        let host = try JSONDecoder().decode(Host.self, from: Data(json.utf8))
        #expect(host.portForwards == nil)
    }
}
