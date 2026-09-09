import AppIntents
import Foundation

/// A saved connection as Siri and Shortcuts see it (D-021): its name, and enough to tell
/// two servers apart when names repeat. Nothing secret is exposed to the system.
struct ConnectionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Connection")
    static let defaultQuery = ConnectionQuery()

    let id: UUID
    let name: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
    }

    init(host: Host) {
        id = host.id
        name = host.name
        subtitle = host.subtitle
    }
}

/// How the intents reach the live container: a handle the app installs at launch, and a
/// test points at a container built on temporary stores. App Intents' own dependency
/// registry was the first design; it asserts inside the framework when an intent runs
/// under test, takes one registration per type per process, and offers no lookup — so
/// the crossing is the app's own, and every intent can be run in a test.
@MainActor
final class IntentContainer {
    static var current: IntentContainer?

    var container: AppContainer
    init(_ container: AppContainer) { self.container = container }

    static func live() throws -> AppContainer {
        guard let current else { throw IntentError.appNotReady }
        return current.container
    }
}

struct ConnectionQuery: EntityQuery {
    @MainActor private var container: AppContainer { get throws { try IntentContainer.live() } }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ConnectionEntity] {
        try container.hostStore.hosts.filter { identifiers.contains($0.id) }.map(ConnectionEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ConnectionEntity] {
        try container.hostStore.hosts.map(ConnectionEntity.init)
    }
}

extension ConnectionQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [ConnectionEntity] {
        let needle = string.lowercased()
        return try container.hostStore.hosts
            .filter { $0.name.lowercased().contains(needle) || $0.hostname.lowercased().contains(needle) }
            .map(ConnectionEntity.init)
    }
}

/// "Connect to <name>": opens the app on a session to that server. The connection itself
/// goes through the same path as a tap on the row — host-key checks, credentials, prompts
/// — because Siri is a way in, not a way around.
struct OpenConnectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to Server"
    static let description = IntentDescription("Opens a terminal session to one of your saved connections.")
    static let openAppWhenRun = true

    @Parameter(title: "Connection")
    var connection: ConnectionEntity

    @MainActor private var container: AppContainer { get throws { try IntentContainer.live() } }

    static var parameterSummary: some ParameterSummary {
        Summary("Connect to \(\.$connection)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let container = try container
        guard let host = container.hostStore.hosts.first(where: { $0.id == connection.id }) else {
            throw IntentError.connectionMissing
        }
        // A session already open to this server is shown rather than doubled.
        let session = container.sessionManager.sessions.first { $0.host.id == host.id }
            ?? container.sessionManager.open(host)
        container.hostStore.markConnected(host)
        container.pendingIntentSessionID = session.id
        container.activeScene?.selectedSessionID = session.id
        return .result()
    }
}

/// "Disconnect everything": closes every open session. Named for what it does.
struct DisconnectAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect All Sessions"
    static let description = IntentDescription("Closes every open terminal session and remote screen.")

    @MainActor private var container: AppContainer { get throws { try IntentContainer.live() } }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try container
        let count = container.sessionManager.sessions.count + container.screens.sessions.count
        container.sessionManager.closeAll()
        container.screens.closeAll()
        return .result(dialog: IntentDialog(Self.dialog(forClosedCount: count)))
    }

    /// Three whole sentences rather than a pluralising suffix, so each language can say
    /// it its own way. Separate from `perform` so a test can read what Siri will say.
    static func dialog(forClosedCount count: Int) -> LocalizedStringResource {
        switch count {
        case 0: "No sessions were open."
        case 1: "Closed one session."
        default: "Closed \(count) sessions."
        }
    }
}

/// A saved snippet as Shortcuts sees it (D-061). Its name and what it runs, because a
/// shortcut that says "run Deploy" and does something else is worse than no shortcut.
struct SnippetEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Snippet")
    static let defaultQuery = SnippetQuery()

    let id: UUID
    let name: String
    let command: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(command)")
    }

    init(snippet: Snippet) {
        id = snippet.id
        name = snippet.name
        command = snippet.command
    }
}

struct SnippetQuery: EntityQuery {
    @MainActor private var container: AppContainer { get throws { try IntentContainer.live() } }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SnippetEntity] {
        try container.snippetStore.snippets.filter { identifiers.contains($0.id) }.map(SnippetEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SnippetEntity] {
        try container.snippetStore.snippets.map(SnippetEntity.init)
    }
}

extension SnippetQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [SnippetEntity] {
        let needle = string.lowercased()
        return try container.snippetStore.snippets
            .filter { $0.name.lowercased().contains(needle) }
            .map(SnippetEntity.init)
    }
}

/// "Run <snippet> on <connection>": opens the session and puts the snippet in it.
///
/// Whether it *runs* is the snippet's own setting, not this intent's. A snippet marked to
/// run immediately runs; one that is not is typed in and left for the person to press
/// Return — which is the same thing that happens when they tap it in the app, and is the
/// difference between automation and a surprise.
struct RunSnippetIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Snippet on Server"
    static let description = IntentDescription(
        "Opens a connection and puts one of your saved snippets into it. Whether it runs straight away is the snippet's own setting."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Snippet")
    var snippet: SnippetEntity

    @Parameter(title: "Connection")
    var connection: ConnectionEntity

    @MainActor private var container: AppContainer { get throws { try IntentContainer.live() } }

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$snippet) on \(\.$connection)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let container = try container
        guard let host = container.hostStore.hosts.first(where: { $0.id == connection.id }) else {
            throw IntentError.connectionMissing
        }
        guard let saved = container.snippetStore.snippets.first(where: { $0.id == snippet.id }) else {
            throw IntentError.snippetMissing
        }
        let session = container.sessionManager.sessions.first { $0.host.id == host.id }
            ?? container.sessionManager.open(host)
        container.hostStore.markConnected(host)
        container.pendingIntentSessionID = session.id
        container.activeScene?.selectedSessionID = session.id
        // Inserted once the shell is there: a session opened by this intent has not
        // connected yet, and sending into it would drop the text.
        Task { @MainActor in
            await session.insertWhenConnected(snippet: saved)
        }
        return .result()
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case connectionMissing
    case snippetMissing
    case appNotReady
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .connectionMissing: "That connection no longer exists."
        case .snippetMissing: "That snippet no longer exists."
        case .appNotReady: "Apex Terminal is still starting. Try again in a moment."
        }
    }
}

/// What Siri offers without setup. Phrases must name the app.
struct ApexTerminalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppIntents.AppShortcut] {
        AppIntents.AppShortcut(
            intent: OpenConnectionIntent(),
            phrases: [
                "Connect to \(\.$connection) in \(.applicationName)",
                "Open \(\.$connection) in \(.applicationName)",
                "SSH to \(\.$connection) with \(.applicationName)",
            ],
            shortTitle: "Connect",
            systemImageName: "terminal"
        )
        // One parameter per phrase, which is Apple's rule and not a stylistic choice:
        // `appshortcutstringsprocessor` rejects a phrase with two, and it only runs when the
        // app is archived — so a spoken phrase naming both the snippet and the connection
        // built and ran perfectly well right up to the point of shipping. Siri asks for
        // whichever of the two was not said.
        AppIntents.AppShortcut(
            intent: RunSnippetIntent(),
            phrases: [
                "Run \(\.$snippet) with \(.applicationName)",
                "Run a snippet on \(\.$connection) with \(.applicationName)",
            ],
            shortTitle: "Run Snippet",
            systemImageName: "text.badge.plus"
        )
        AppIntents.AppShortcut(
            intent: DisconnectAllIntent(),
            phrases: ["Disconnect all sessions in \(.applicationName)"],
            shortTitle: "Disconnect All",
            systemImageName: "bolt.slash"
        )
    }
}
