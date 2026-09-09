import Foundation
import STCore

/// A link that asks this app to do something (D-061).
///
/// Two schemes are answered. `ssh://` is the one people already have in notes, wikis and
/// READMEs; `apexterminal://` is this app's own, for the things a generic SSH URL cannot
/// say — which saved connection to use, and what to run on it.
///
/// The parsing is deliberately separate from what the app *does* with the result. A URL
/// arrives from anywhere: a web page, a message from a stranger, a QR code. Turning one
/// into an action is arithmetic; deciding whether to carry it out is a security decision,
/// and it is made in one place — ``authorisation`` — where it can be read and tested.
enum IncomingURL: Equatable {
    /// A server named by the link itself, as `ssh://user@host:port` does.
    case address(SSHAddress)
    /// A saved connection, named by id or by name.
    case savedConnection(reference: String, command: String?)

    struct SSHAddress: Equatable {
        var username: String?
        var host: String
        var port: Int?
        var command: String?
    }

    /// What the app may do with a link without asking first.
    enum Authorisation: Equatable {
        /// Open it. Nothing runs, and the connection is one the user already saved.
        case openDirectly
        /// Ask first, and say exactly what will happen.
        ///
        /// Everything else lands here: a server this device has never been told about, and
        /// anything at all that carries a command. A link is untrusted input, and a
        /// terminal that runs what a link says without asking is a remote-execution
        /// primitive with a nice icon.
        case confirm(Reason)
    }

    enum Reason: Equatable {
        case unknownServer
        case runsACommand
    }

    /// The command the link carries, if any.
    var command: String? {
        switch self {
        case let .address(address): address.command
        case let .savedConnection(_, command): command
        }
    }

    /// Whether this link may be acted on without asking, given what is already saved.
    ///
    /// - Parameter isSaved: whether the link names a connection this device already has.
    func authorisation(isSaved: Bool) -> Authorisation {
        if command != nil { return .confirm(.runsACommand) }
        return isSaved ? .openDirectly : .confirm(.unknownServer)
    }

    /// Parses a link, or returns `nil` for one this app has nothing to do with.
    init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased()
        else { return nil }

        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item in item.value.map { (item.name.lowercased(), $0) } },
            uniquingKeysWith: { first, _ in first }
        )

        switch scheme {
        case "ssh":
            // `ssh://user@host:port`. A host is the one part that cannot be left out.
            guard let host = components.host, !host.isEmpty else { return nil }
            self = .address(SSHAddress(
                username: components.user.flatMap { $0.isEmpty ? nil : $0 },
                // `URLComponents` hands back an IPv6 literal with its brackets — they are
                // the URL's way of keeping the colons apart from the port, and are not
                // part of the address. Left in, they become a hostname that never resolves.
                host: Self.withoutBrackets(host),
                port: components.port,
                // Not part of the URI scheme, but the thing every other client's users ask
                // for, and safe here because it is never run without being shown first.
                command: Self.trimmed(query["command"])
            ))

        case "apexterminal":
            // `apexterminal://open?host=…` and `apexterminal://run?host=…&command=…`.
            let action = (components.host ?? "").lowercased()
            guard action == "open" || action == "run" else { return nil }
            let command = action == "run" ? Self.trimmed(query["command"]) : nil
            if action == "run", command == nil { return nil }

            if let reference = Self.trimmed(query["host"]) {
                self = .savedConnection(reference: reference, command: command)
            } else if let address = Self.trimmed(query["address"]) {
                // A full address instead of a saved connection, so a link can name a server
                // this device has never seen — which is exactly the case that must be
                // confirmed.
                guard let parsed = HostAddress.parse(address) else { return nil }
                self = .address(SSHAddress(
                    username: parsed.user,
                    host: parsed.host,
                    port: parsed.port,
                    command: command
                ))
            } else {
                return nil
            }

        default:
            return nil
        }
    }

    static func withoutBrackets(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 else { return host }
        return String(host.dropFirst().dropLast())
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
