import Foundation
import Network

/// What a person types — or pastes — into a hostname field, taken apart: the host, and
/// the port and user name if they came along with it.
///
/// A Cloudflare hostname copied from a dashboard arrives as `ssh.example.com:443`; an
/// SSH address copied from a terminal arrives as `ssh://deploy@build.example.com:2222/`;
/// an IPv6 literal arrives as `[2001:db8::1]:22`. Treating any of those as the hostname
/// itself fails name resolution with a message that blames the network. Only the host is
/// a host; the rest goes where it belongs.
public struct HostAddress: Equatable, Sendable {
    public var host: String
    public var port: Int?
    public var user: String?

    public init(host: String, port: Int? = nil, user: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
    }

    /// `nil` when nothing usable is there: empty text, a bracket that never closes, a
    /// port that is not a port.
    public static func parse(_ text: String) -> HostAddress? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !rest.isEmpty else { return nil }

        // A pasted URL: the scheme, path, query and fragment say nothing about the host.
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { rest = rest[..<end] }

        var user: String?
        if let at = rest.lastIndex(of: "@") {
            let name = rest[..<at]
            // `user:password@host` from a URL: the name is kept, a password is never.
            let bare = name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            user = bare.isEmpty ? nil : bare
            rest = rest[rest.index(after: at)...]
        }
        guard !rest.isEmpty else { return nil }

        // An IPv6 literal keeps its colons inside brackets; a port may follow.
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            let host = String(rest[rest.index(after: rest.startIndex) ..< close])
            guard !host.isEmpty else { return nil }
            let tail = rest[rest.index(after: close)...]
            if tail.isEmpty { return HostAddress(host: host, port: nil, user: user) }
            guard tail.hasPrefix(":"), let port = validPort(tail.dropFirst()) else { return nil }
            return HostAddress(host: host, port: port, user: user)
        }

        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return HostAddress(host: String(rest), port: nil, user: user)
        case 2:
            guard !parts[0].isEmpty, let port = validPort(parts[1]) else { return nil }
            return HostAddress(host: String(parts[0]), port: port, user: user)
        default:
            // Several colons and no brackets: a bare IPv6 address, or nothing. The system
            // decides which — "a:b:c" is three hex groups and no address at all, which a
            // character-set test cannot tell apart from one.
            guard IPv6Address(String(rest)) != nil else { return nil }
            return HostAddress(host: String(rest), port: nil, user: user)
        }
    }

    private static func validPort(_ text: Substring) -> Int? {
        guard let port = Int(text), (1 ... 65535).contains(port) else { return nil }
        return port
    }
}
