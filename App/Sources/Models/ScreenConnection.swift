import CryptoKit
import Foundation

/// A saved remote screen (D-027): its own connection, configured on its own, reached
/// through a saved SSH connection or straight over the network.
///
/// It holds no secret. The VNC password lives in the Keychain under this record's id, so
/// exporting or syncing a screen can never carry it along — the same rule the SSH host
/// list follows.
public struct ScreenConnection: Identifiable, Sendable, Codable, Equatable {
    public var id: UUID
    public var name: String
    /// The VNC server's address. Through SSH it is the address as *that server* sees it —
    /// `127.0.0.1` for the server's own desktop — because the connection is made from
    /// there. Direct, it is what this device dials.
    public var address: String
    public var port: Int
    public var route: Route
    /// Whether a VNC password is in this device's Keychain for this screen. The claim
    /// syncs; the password never does.
    public var hasPassword: Bool
    public var folder: String?
    public var tags: [String]
    public var lastConnected: Date?
    /// When this record last changed, on any device. Optional for the same reason as
    /// `Host.modifiedAt`: records written before sync existed carry no such field.
    public var modifiedAt: Date?

    /// How the screen is reached.
    ///
    /// Through a saved SSH connection by default (D-022): a `direct-tcpip` channel on that
    /// connection, the way `ssh -L` works, so the desktop needs nothing exposed and the
    /// picture is inside SSH's encryption. The alternative is a direct TCP connection,
    /// which RFB carries in the clear.
    public enum Route: Sendable, Codable, Equatable {
        case throughSSH(hostID: UUID)
        case direct

        public var sshHostID: UUID? {
            if case let .throughSSH(id) = self { return id }
            return nil
        }

        public var isDirect: Bool {
            if case .direct = self { return true }
            return false
        }
    }

    public static let defaultPort = 5900

    public init(
        id: UUID = UUID(),
        name: String,
        address: String = "127.0.0.1",
        port: Int = ScreenConnection.defaultPort,
        route: Route,
        hasPassword: Bool = false,
        folder: String? = nil,
        tags: [String] = [],
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.route = route
        self.hasPassword = hasPassword
        self.folder = folder
        self.tags = tags
        self.lastConnected = lastConnected
    }

    /// `127.0.0.1`, or `10.0.0.2:5901` when the port is not the default.
    public var endpoint: String {
        port == Self.defaultPort ? address : "\(address):\(port)"
    }

    public var validationProblems: [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append(String(localized: "Give this screen a name.")) }
        if address.trimmingCharacters(in: .whitespaces).isEmpty { problems.append(String(localized: "Enter the screen's address.")) }
        if !(1 ... 65535).contains(port) { problems.append(String(localized: "Port must be between 1 and 65535.")) }
        return problems
    }

    /// The id a screen migrated from a connection's old `vnc` block takes.
    ///
    /// Derived from the SSH connection's id rather than random, so two devices migrating
    /// the same connection independently arrive at the same screen and sync merges them
    /// instead of showing the screen twice. This is a name-based UUID (version 5) under a
    /// namespace of the app's own.
    public static func migratedID(fromHostID id: UUID) -> UUID {
        let namespace = UUID(uuidString: "1B0A6C4E-3B7F-5A2D-9E10-0C6F2A7D4B83")!
        var input = Data()
        withUnsafeBytes(of: namespace.uuid) { input.append(contentsOf: $0) }
        input.append(Data(id.uuidString.lowercased().utf8))
        var digest = Array(Insecure.SHA1.hash(data: input).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

/// What the New Connection sheet offers (D-027).
enum ConnectionKind: String, CaseIterable, Identifiable {
    case ssh
    case screen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ssh: String(localized: "Terminal")
        case .screen: String(localized: "Screen")
        }
    }

    var systemImage: String {
        switch self {
        case .ssh: "terminal"
        case .screen: "display"
        }
    }
}
