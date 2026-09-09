import Foundation
import Testing
@testable import ApexTerminal

/// Siri and Shortcuts go through the same container as a tap (D-021). These tests run
/// the intents against a container built on temporary stores: the session an intent
/// opens is a real one that starts connecting, so they use a port nothing listens on and
/// look only at what the intent itself decides.
@Suite("App Intents", .serialized)
struct AppIntentTests {
    @MainActor
    private func makeContainer() throws -> (AppContainer, Host) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = AppContainer.testInstance(directory: directory)
        let host = Host(name: "Build box", hostname: "127.0.0.1", port: 1, username: "me", credentials: [.password])
        container.hostStore.add(host)
        // The intents follow the handle (D-021); a test points it at its own container.
        IntentContainer.current = IntentContainer(container)
        return (container, host)
    }

    @Test("The query finds connections by name or hostname and exposes nothing secret")
    @MainActor func queryMatches() async throws {
        let (container, host) = try makeContainer()
        let byName = try await ConnectionQuery().entities(matching: "build")
        #expect(byName.map(\.id) == [host.id])
        let byHost = try await ConnectionQuery().entities(matching: "127.0.0")
        #expect(byHost.count == 1)
        let none = try await ConnectionQuery().entities(matching: "nothing here")
        #expect(none.isEmpty)
        let suggested = try await ConnectionQuery().suggestedEntities()
        #expect(suggested.first?.name == "Build box")
        #expect(suggested.first?.subtitle == host.subtitle, "the row's subtitle, never a credential")
        _ = container
    }

    @Test("Connect opens one session, records the connection, and hands it to the next window")
    @MainActor func connectOpensASession() async throws {
        let (container, host) = try makeContainer()
        let intent = OpenConnectionIntent()
        intent.connection = ConnectionEntity(host: host)
        _ = try await intent.perform()
        #expect(container.sessionManager.sessions.count == 1)
        #expect(container.sessionManager.sessions.first?.host.id == host.id)
        #expect(container.pendingIntentSessionID == container.sessionManager.sessions.first?.id)
        #expect(container.hostStore.hosts.first?.lastConnected != nil)
        // Asking again shows the same session rather than doubling it.
        _ = try await intent.perform()
        #expect(container.sessionManager.sessions.count == 1)
        container.sessionManager.closeAll()
    }

    @Test("Run Snippet opens the connection and offers the snippet it names")
    @MainActor func runSnippetOpensTheSession() async throws {
        let (container, host) = try makeContainer()
        let snippet = Snippet(id: UUID(), name: "Uptime", command: "uptime", runsImmediately: false)
        container.snippetStore.add(snippet)

        let intent = RunSnippetIntent()
        intent.connection = ConnectionEntity(host: host)
        intent.snippet = SnippetEntity(snippet: snippet)
        _ = try await intent.perform()

        #expect(container.sessionManager.sessions.count == 1)
        #expect(container.sessionManager.sessions.first?.host.id == host.id)
        #expect(container.pendingIntentSessionID == container.sessionManager.sessions.first?.id)
        container.sessionManager.closeAll()
    }

    @Test("A shortcut naming a snippet that has gone says so rather than running something else")
    @MainActor func runSnippetWithoutTheSnippet() async throws {
        let (container, host) = try makeContainer()
        let intent = RunSnippetIntent()
        intent.connection = ConnectionEntity(host: host)
        intent.snippet = SnippetEntity(snippet: Snippet(id: UUID(), name: "Gone", command: "true", runsImmediately: false))
        await #expect(throws: IntentError.self) { _ = try await intent.perform() }
        container.sessionManager.closeAll()
    }

    @Test("The snippet query exposes the command, because a shortcut must say what it runs")
    @MainActor func snippetQuery() async throws {
        let (container, _) = try makeContainer()
        container.snippetStore.add(Snippet(id: UUID(), name: "Deploy", command: "make deploy", runsImmediately: true))
        let matches = try await SnippetQuery().entities(matching: "dep")
        #expect(matches.map(\.name) == ["Deploy"])
        #expect(matches.first?.command == "make deploy")
    }

    @Test("Disconnect All says what it did")
    @MainActor func disconnectAllDialog() async throws {
        let (container, host) = try makeContainer()
        #expect(String(localized: DisconnectAllIntent.dialog(forClosedCount: 0)).contains("No sessions were open"))
        #expect(String(localized: DisconnectAllIntent.dialog(forClosedCount: 1)).contains("Closed one session"))
        #expect(String(localized: DisconnectAllIntent.dialog(forClosedCount: 3)).contains("Closed 3 sessions"))
        _ = try await DisconnectAllIntent().perform()
        container.sessionManager.open(host)
        #expect(container.sessionManager.sessions.count == 1)
        _ = try await DisconnectAllIntent().perform()
        #expect(container.sessionManager.sessions.isEmpty)
    }
}
