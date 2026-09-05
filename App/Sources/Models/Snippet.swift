import Foundation

/// A saved command.
///
/// Typing on glass is slow and error-prone, and the commands people run on a phone are
/// overwhelmingly ones they have run before. A snippet is not a macro system — it is the
/// command, a name, and whether pressing it should also press Return.
public struct Snippet: Identifiable, Sendable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var command: String
    /// Whether to send Return after the command.
    ///
    /// Off by default, and deliberately so: inserting the text and letting the person
    /// press Return themselves means a snippet can be reviewed, edited, or abandoned
    /// before it runs. A snippet that runs the instant it is tapped is one mis-tap away
    /// from something irreversible.
    public var runsImmediately: Bool
    /// Optional grouping, so a long list stays navigable.
    public var folder: String?
    public var createdAt: Date
    /// Bumped each time the snippet is used, so the list can put the useful ones first.
    public var useCount: Int
    public var lastUsed: Date?
    /// See `Host.modifiedAt`: optional so files from before sync still decode.
    public var modifiedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        runsImmediately: Bool = false,
        folder: String? = nil,
        createdAt: Date = Date(),
        useCount: Int = 0,
        lastUsed: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.runsImmediately = runsImmediately
        self.folder = folder
        self.createdAt = createdAt
        self.useCount = useCount
        self.lastUsed = lastUsed
    }

    public var validationProblems: [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append(String(localized: "Give this snippet a name.")) }
        if command.trimmingCharacters(in: .whitespaces).isEmpty { problems.append(String(localized: "Enter a command.")) }
        return problems
    }

    /// Whether the command spans several lines, which changes how it should be sent.
    public var isMultiline: Bool { command.contains("\n") || command.contains("\r") }

    /// Snippets a new install starts with.
    ///
    /// Chosen to be useful on a phone and harmless if run by accident: everything here
    /// reads state rather than changing it. A starter set that included `rm` or a service
    /// restart would be teaching the wrong habit on the first run.
    ///
    /// Names and folders are labels the person can rename afterwards, so seeding them in
    /// the current language is safe: installation dedupes on `command`, which stays a
    /// literal, and nothing anywhere matches a snippet by its name or folder.
    public static let starterSet: [Snippet] = [
        Snippet(name: String(localized: "Disk usage"), command: "df -h", folder: String(localized: "System")),
        Snippet(name: String(localized: "Memory"), command: "free -h 2>/dev/null || vm_stat", folder: String(localized: "System")),
        Snippet(name: String(localized: "Top processes"), command: "ps aux --sort=-%cpu 2>/dev/null | head -20 || ps aux | head -20", folder: String(localized: "System")),
        Snippet(name: String(localized: "Listening ports"), command: "ss -tlnp 2>/dev/null || netstat -an | grep LISTEN", folder: String(localized: "System")),
        Snippet(name: String(localized: "Uptime and load"), command: "uptime", folder: String(localized: "System")),
        Snippet(name: String(localized: "Recent auth failures"), command: "journalctl -u ssh -n 50 --no-pager 2>/dev/null || tail -50 /var/log/auth.log", folder: String(localized: "Diagnostics")),
        Snippet(name: String(localized: "Follow a log"), command: "tail -f /var/log/syslog", folder: String(localized: "Diagnostics")),
        Snippet(name: String(localized: "Largest directories"), command: "du -sh * 2>/dev/null | sort -rh | head -20", folder: String(localized: "Diagnostics")),
    ]
}

/// One command the user ran, if history is switched on.
public struct HistoryEntry: Identifiable, Sendable, Codable, Equatable {
    public var id: UUID
    public var command: String
    /// The host it was run against, so history from one server is not offered on another.
    public var hostID: UUID
    public var hostName: String
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        command: String,
        hostID: UUID,
        hostName: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.command = command
        self.hostID = hostID
        self.hostName = hostName
        self.timestamp = timestamp
    }
}
