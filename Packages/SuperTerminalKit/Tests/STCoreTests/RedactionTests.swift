import Testing
@testable import STCore

@Suite("Redaction")
struct RedactionTests {
    @Test("Redacted values never render their contents")
    func redactedDescriptionHidesValue() {
        let secret = Redacted("hunter2", label: "password")
        #expect(!"\(secret)".contains("hunter2"))
        #expect(secret.reveal() == "hunter2")
    }
}
