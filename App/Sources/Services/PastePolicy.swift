import Foundation

/// Decides what should happen when the user pastes.
///
/// Split out from ``TerminalSession`` so the rule can be tested for what it is — a
/// policy — rather than only as a side effect of a live connection. A test that
/// exercises this through a session would pass whether or not the rule existed, because
/// an unconnected session refuses to paste anyway.
enum PastePolicy {
    enum Decision: Equatable {
        /// Send it straight through.
        case send
        /// Ask the user first, because a newline would execute what follows.
        case confirm
        /// Nothing to do.
        case ignore
    }

    /// - Parameters:
    ///   - text: what the user is pasting.
    ///   - confirmMultiline: the user's preference.
    ///   - bracketedPaste: whether the remote program asked for bracketed paste, which
    ///     stops a shell executing pasted newlines.
    static func decide(
        text: String,
        confirmMultiline: Bool,
        bracketedPaste: Bool
    ) -> Decision {
        guard !text.isEmpty else { return .ignore }
        guard confirmMultiline else { return .send }

        let containsNewline = text.contains("\n") || text.contains("\r")
        guard containsNewline else { return .send }

        // Bracketed paste is still confirmed. It protects a shell that implements it, but
        // the terminal cannot tell what is actually reading its input — a program running
        // under the shell may have set the mode and then handed input to something that
        // does not honour it. The confirmation costs one tap; getting it wrong runs a
        // command the user never typed.
        _ = bracketedPaste
        return .confirm
    }
}
