import Foundation
import Testing

@testable import ApexTerminal

/// What can go in the other half of a split (D-074).
///
/// ⌘D means "another one of these", which is right for a second shell on the machine you are
/// already looking at and wrong for everything else people actually put side by side: a
/// different server, a machine's screen over VNC, a folder — or a server that is not in the
/// list yet. These pin the vocabulary and the resolution, which is where the behaviour is.
@Suite("Splitting with something else")
@MainActor
struct SplitTargetTests {
    private func makeContainer() -> AppContainer {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory() + "split-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AppContainer.testInstance(directory: directory)
    }

    private func host(_ name: String, tmux: Bool = false) -> Host {
        var host = Host(
            name: name,
            hostname: "\(name.lowercased()).test",
            port: 22,
            username: "someone",
            transport: .directTCP
        )
        host.usesTmux = tmux
        return host
    }

    @Test("A saved connection becomes a shell in the new pane")
    func savedConnectionOpensAShell() {
        let container = makeContainer()
        let server = host("Alpha")
        container.hostStore.add(server)

        let content = SplitTargetResolver(container: container).paneContent(for: .newSession(server.id))
        guard case let .terminal(id)? = content else {
            Issue.record("a saved connection should open a shell, got \(String(describing: content))")
            return
        }
        // A *new* session, not a second reference to one that was already there: two panes on
        // the same server is two shells, which is what connection reuse (D-054) makes cheap.
        #expect(container.sessionManager.sessions.map(\.id) == [id])
        #expect(container.sessionManager.session(withID: id)?.host.id == server.id)
    }

    @Test("A connection that asked for tmux attaches instead of opening a plain shell")
    func tmuxConnectionAttaches() {
        let container = makeContainer()
        let server = host("Beta", tmux: true)
        container.hostStore.add(server)

        let content = SplitTargetResolver(container: container).paneContent(for: .newTmuxSession(server.id))
        guard case let .tmux(id)? = content else {
            Issue.record("a tmux connection should attach, got \(String(describing: content))")
            return
        }
        #expect(container.tmux.session(withID: id) != nil)
        #expect(container.sessionManager.sessions.isEmpty, "and no plain shell alongside it")
    }

    @Test("A folder is something a pane can hold too")
    func fileBrowserIsATarget() {
        let container = makeContainer()
        let server = host("Gamma")
        container.hostStore.add(server)

        let content = SplitTargetResolver(container: container).paneContent(for: .newFileBrowser(server.id))
        guard case let .files(id)? = content else {
            Issue.record("expected a file browser, got \(String(describing: content))")
            return
        }
        #expect(container.sessionManager.fileSession(id: id)?.hostID == server.id)
    }

    @Test("Something already open is shown, not opened a second time")
    func openThingsAreReused() {
        let container = makeContainer()
        let server = host("Delta")
        container.hostStore.add(server)
        let existing = container.sessionManager.open(server)

        let content = SplitTargetResolver(container: container).paneContent(for: .openSession(existing.id))
        #expect(content == .terminal(existing.id))
        #expect(container.sessionManager.sessions.count == 1, "showing an open session must not start another")
    }

    @Test("A connection that is not there resolves to nothing rather than to something wrong")
    func missingConnectionIsRefused() {
        let container = makeContainer()
        let resolver = SplitTargetResolver(container: container)
        #expect(resolver.paneContent(for: .newSession(UUID())) == nil)
        #expect(resolver.paneContent(for: .newScreen(UUID())) == nil)
        // The two "not in the list yet" choices are answered by an editor, not by a pane.
        #expect(resolver.paneContent(for: .addConnection) == nil)
        #expect(resolver.paneContent(for: .addScreen) == nil)
    }

    @Test("A pane whose session ended is replaced, not split")
    func replacingAPane() {
        var layout = PaneLayout()
        let first = UUID()
        layout.show(.terminal(first))
        let paneID = try! #require(layout.focused)

        let second = UUID()
        layout.replace(paneID, with: .screen(second))

        // One pane, showing the new thing. Splitting there would have left the dead session
        // on screen beside the new one, which is not what "show something else here" means.
        #expect(layout.paneCount == 1)
        #expect(layout.panes.map(\.content) == [.screen(second)])
        #expect(layout.focused == paneID)
    }

    @Test("Replacing a pane that is not there changes nothing")
    func replacingAMissingPane() {
        var layout = PaneLayout()
        layout.show(.terminal(UUID()))
        let before = layout.panes.map(\.content)
        layout.replace(UUID(), with: .screen(UUID()))
        #expect(layout.panes.map(\.content) == before)
    }

    @Test("A split names the pane it is for, and a replacement names the pane it replaces")
    func placementCarriesItsTarget() {
        #expect(PendingSplit(placement: .split(.horizontal)).axis == .horizontal)
        #expect(PendingSplit(placement: .split(.vertical)).axis == .vertical)
        #expect(PendingSplit(placement: .replace(UUID())).axis == nil)
        // Two requests are two requests: the picker is presented by identity, and a second
        // ⌥⌘D while one is open must not be swallowed as "the same sheet".
        #expect(PendingSplit(placement: .split(.horizontal)) != PendingSplit(placement: .split(.horizontal)))
    }
}
