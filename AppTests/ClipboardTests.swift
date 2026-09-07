import Foundation
import Testing
import UIKit
@testable import ApexTerminal

@Suite struct ClipboardTests {
    @Test func zeroMeansNoExpiry() {
        #expect(Clipboard.options(expiringAfter: 0).isEmpty)
        #expect(Clipboard.options(expiringAfter: -5).isEmpty)
    }

    @Test func positiveSecondsSetAHardExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let options = Clipboard.options(expiringAfter: 90, now: now)
        let expiry = try #require(options[.expirationDate] as? Date)
        #expect(expiry == now.addingTimeInterval(90))
    }

    /// The real pasteboard, in the app host: the copied text must be readable back the
    /// way every paste path reads it, and an expiry must not make it unreadable now.
    @Test @MainActor func copiedTextIsReadableUntilItExpires() {
        let text = "echo clipboard-\(UUID().uuidString)"
        Clipboard.copy(text, expiringAfter: 60)
        #expect(UIPasteboard.general.string == text)
        Clipboard.copy("", expiringAfter: 0)
    }
}
