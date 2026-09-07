import Testing
@testable import STCloudflare

@Suite("Base64URL")
struct Base64URLTests {
    @Test("Round-trips unpadded base64url")
    func roundTrip() throws {
        let data = Data([0xFB, 0xEF, 0xFF, 0x01])
        #expect(Base64URL.decode(Base64URL.encode(data)) == data)
    }
}
import Foundation
