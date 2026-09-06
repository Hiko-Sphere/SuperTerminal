import Foundation

/// What the tour teaches, in order (D-033).
///
/// Six things, each one a thing the app can do that a person would not otherwise find:
/// paste an address instead of filling a form, what the fingerprint is for, how to type a
/// control character on a phone, how to stop retyping commands, that a screen is not only
/// a terminal, and where the keys actually live. Nothing here sells the app to someone who
/// has already installed it.
///
/// Separated from the view so the content is testable and the order is a fact about the
/// app rather than a fact about a layout.
struct TutorialPage: Identifiable, Equatable {
    enum Illustration: Equatable {
        case address, fingerprint, keyRow, palette, screen, keychain
    }

    let id: Int
    let symbol: String
    let title: String
    let body: String
    let illustration: Illustration

    static let all: [TutorialPage] = [
        TutorialPage(
            id: 0,
            symbol: "square.and.arrow.down.on.square",
            title: String(localized: "Paste the address"),
            body: String(localized: "Paste deploy@build.example.com:2222 into the hostname field and it is taken apart for you. A blank port means the usual one; a blank user name is asked for when you connect."),
            illustration: .address
        ),
        TutorialPage(
            id: 1,
            symbol: "checkmark.seal",
            title: String(localized: "You verify the first fingerprint"),
            body: String(localized: "On a first connection only you can tell your server from an impostor. Check the fingerprint once; after that it is remembered, and a key that changes is refused until you say otherwise."),
            illustration: .fingerprint
        ),
        TutorialPage(
            id: 2,
            symbol: "keyboard",
            title: String(localized: "Keys a phone keyboard does not have"),
            body: String(localized: "The row above the keyboard has Control, Escape, Tab and the arrows. Tap Control and it latches for the next key, so Control then C sends ^C. An external keyboard works too."),
            illustration: .keyRow
        ),
        TutorialPage(
            id: 3,
            symbol: "command",
            title: String(localized: "Stop retyping the same command"),
            body: String(localized: "Save the commands you run often as snippets, one tap away in any session. The command palette — ⌘K — searches your connections, snippets and every action at once."),
            illustration: .palette
        ),
        TutorialPage(
            id: 4,
            symbol: "display",
            title: String(localized: "Not only a terminal"),
            body: String(localized: "A remote screen shows the whole desktop over VNC. Tap to click, hold to drag, two fingers to scroll, or use a keyboard and mouse. It can travel inside an SSH connection, so nothing need be exposed."),
            illustration: .screen
        ),
        TutorialPage(
            id: 5,
            symbol: "lock.shield",
            title: String(localized: "Everything stays yours"),
            body: String(localized: "Private keys stay in this device's Keychain and never reach a server. There is no account and no analytics. Turn on iCloud sync, or a passcode and Face ID, only if you want them."),
            illustration: .keychain
        ),
    ]
}
