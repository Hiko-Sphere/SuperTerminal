import Foundation
import STCloudflare
import Testing
@testable import SuperTerminal

@Suite struct ServiceTokenTests {
    @Test func hostsWrittenBeforeTheFieldExistedStillDecode() throws {
        let host = Host(name: "old", hostname: "h.example", username: "u")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as! [String: Any]
        object.removeValue(forKey: "accessAuthentication")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Host.self, from: data)
        #expect(decoded.accessAuthentication == nil)
        #expect(!decoded.usesServiceToken)
    }

    @Test func fieldRoundTripsThroughCodable() throws {
        var host = Host(name: "cf", hostname: "cf.example", username: "u", transport: .cloudflare(jumpDestination: nil))
        host.accessAuthentication = .serviceToken
        let back = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host))
        #expect(back.usesServiceToken)
    }

    /// The real Keychain in the app host: store, read back, and delete — and the secret
    /// comes back redacted in any description, revealed only on request.
    @Test func vaultStoresLoadsAndDeletesAServiceToken() throws {
        let vault = CredentialVault()
        let hostID = UUID()
        defer { try? vault.deleteServiceToken(hostID: hostID) }
        #expect(!vault.hasServiceToken(hostID: hostID))
        try vault.storeServiceToken(clientID: "abc.access", secret: "s3cr3t-value", hostID: hostID)
        #expect(vault.hasServiceToken(hostID: hostID))
        let token = try #require(try vault.loadServiceToken(hostID: hostID))
        #expect(token.clientID == "abc.access")
        #expect(token.clientSecret.reveal() == "s3cr3t-value")
        #expect(!String(describing: token.clientSecret).contains("s3cr3t"))
        try vault.deleteServiceToken(hostID: hostID)
        #expect(try vault.loadServiceToken(hostID: hostID) == nil)
    }
}
