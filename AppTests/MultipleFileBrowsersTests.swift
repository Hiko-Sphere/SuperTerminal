import Foundation
import STCore
import STSSH
import Testing

@testable import ApexTerminal

/// Several remote folders open at once (D-071).
///
/// A file browser used to be a sheet built on the spot, which is why there could only ever be
/// one: nothing held it, so nothing could point at a second. It is a session now — kept by the
/// same manager that keeps shells, with an identity, a place in the pane tree and a way to be
/// closed.
@Suite("Several file browsers")
@MainActor
struct MultipleFileBrowsersTests {
    private func manager() -> SessionManager {
        SessionManager(
            vault: CredentialVault(),
            knownHosts: InMemoryKnownHostsStore(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "browsers-\(UUID())")!),
            diagnostics: DiagnosticsCentre()
        )
    }

    private func host(_ name: String) -> Host {
        Host(name: name, hostname: "example.invalid", port: 22, username: "someone", transport: .directTCP)
    }

    @Test("Two folders on the same server are two browsers, not one moved")
    func twoOnTheSameHost() {
        let manager = manager()
        let server = host("Server")
        let first = manager.openFiles(server)
        let second = manager.openFiles(server)

        #expect(first.id != second.id, "opening again must not hand back the first one")
        #expect(manager.fileSessions.count == 2)
        #expect(manager.fileSessions.map(\.hostID) == [server.id, server.id])
        // And each can be found by the id a pane or a route carries.
        #expect(manager.fileSession(id: first.id)?.id == first.id)
        #expect(manager.fileSession(id: second.id)?.id == second.id)
    }

    @Test("Closing one leaves the other open")
    func closingOne() {
        let manager = manager()
        let first = manager.openFiles(host("One"))
        let second = manager.openFiles(host("Two"))

        manager.closeFiles(first)
        #expect(manager.fileSessions.map(\.id) == [second.id])
        #expect(manager.fileSession(id: first.id) == nil)
    }

    @Test("A browser is something the arrangement can show")
    func theSceneCanShowOne() {
        let scene = SceneState()
        let id = UUID()
        scene.show(files: id)

        #expect(scene.selectedFilesSessionID == id)
        #expect(scene.panes.panes.map(\.content) == [.files(id)])
        // Choosing replaces the arrangement, the way choosing a shell does (D-055).
        #expect(scene.selectedSessionID == nil)
        #expect(scene.selectedScreenID == nil)
        #expect(scene.selectedTmuxSessionID == nil)
    }

    @Test("Two browsers can be side by side, and each pane knows which one it holds")
    func twoInPanes() {
        let scene = SceneState()
        let left = UUID()
        let right = UUID()
        scene.show(files: left)
        _ = scene.panes.split(.files(right), axis: .horizontal)

        #expect(scene.panes.paneCount == 2)
        #expect(Set(scene.panes.panes.map(\.content)) == [.files(left), .files(right)])
    }

    @Test("A route and a pane say the same thing about a browser")
    func routeAndPaneAgree() {
        let id = UUID()
        #expect(SessionRoute.files(id).paneContent == .files(id))
        #expect(PaneLayout.Content.files(id).sessionID == id)
    }
}
