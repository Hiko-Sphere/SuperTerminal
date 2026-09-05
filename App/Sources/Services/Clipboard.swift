import UIKit
import UniformTypeIdentifiers

/// Copies terminal text so that iOS removes it from the pasteboard after the configured
/// interval. Terminal output routinely contains tokens, passwords echoed by mistake and
/// URLs with credentials in them; a pasteboard that keeps them until the next copy is a
/// second store of secrets. The expiry is enforced by the system, not by a timer the app
/// would have to be running to fire.
enum Clipboard {
    static func copy(_ text: String, expiringAfter seconds: Int) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: options(expiringAfter: seconds)
        )
    }

    /// 0 means "until replaced"; anything else is a hard expiry relative to `now`.
    static func options(expiringAfter seconds: Int, now: Date = Date()) -> [UIPasteboard.OptionsKey: Any] {
        guard seconds > 0 else { return [:] }
        return [.expirationDate: now.addingTimeInterval(TimeInterval(seconds))]
    }
}
