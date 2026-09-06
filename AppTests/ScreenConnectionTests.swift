import Foundation
import STCore
import Testing
@testable import SuperTerminal

/// A screen as its own connection (D-027): the record, the migration out of the SSH
/// connection that used to hold it, and the store that keeps them.
@Suite("Remote screens as their own connections", .serialized)
struct ScreenConnectionTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("The record round-trips, validates what it needs, and shows its endpoint")
    func record() throws {
        let screen = ScreenConnection(
            name: "Desk", address: "10.0.0.2", port: 5901,
            route: .throughSSH(hostID: UUID()), hasPassword: true
        )
        let back = try JSONDecoder().decode(ScreenConnection.self, from: JSONEncoder().encode(screen))
        #expect(back == screen)
        #expect(screen.endpoint == "10.0.0.2:5901")
        #expect(ScreenConnection(name: "D", address: "127.0.0.1", route: .direct).endpoint == "127.0.0.1",
                "the default port is not worth showing")
        #expect(screen.validationProblems.isEmpty)

        let empty = ScreenConnection(name: "", address: "", port: 0, route: .direct)
        #expect(empty.validationProblems.count == 3)
    }

    @Test("The route says how it connects, and never both ways")
    func route() {
        let id = UUID()
        let through = ScreenConnection.Route.throughSSH(hostID: id)
        #expect(through.sshHostID == id)
        #expect(!through.isDirect)
        #expect(ScreenConnection.Route.direct.sshHostID == nil)
        #expect(ScreenConnection.Route.direct.isDirect)
    }

    /// Two devices migrating the same connection must arrive at one screen, or the user
    /// sees it twice and neither copy is the real one.
    @Test("A migrated screen's id is derived from the connection, so every device agrees")
    func migratedIDIsStable() {
        let host = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
        let first = ScreenConnection.migratedID(fromHostID: host)
        #expect(first == ScreenConnection.migratedID(fromHostID: host), "the same input gives the same id")
        #expect(first != ScreenConnection.migratedID(fromHostID: UUID()), "a different connection is a different screen")
        // A name-based (version 5) UUID: the version nibble is 5 and the variant bits are
        // RFC 4122's, so the value is derived rather than random.
        #expect(first.uuid.6 >> 4 == 0x5, "version nibble should be 5; got \(first.uuidString)")
        #expect(first.uuid.8 >> 6 == 0b10, "variant bits should be RFC 4122's")
    }

    @Test("An old connection's screen settings become a screen, keeping what it actually dialled")
    func migrationMapping() {
        let hostID = UUID()
        var throughSSH = Host(id: hostID, name: "Build box", hostname: "build.example.com", username: "me", credentials: [.password])
        throughSSH.vnc = Host.VNCSettings(port: 5901, viaSSH: true, targetHost: "10.0.0.2", hasPassword: true)
        let screen = try! #require(ScreenMigration.screen(fromLegacy: throughSSH))
        #expect(screen.id == ScreenConnection.migratedID(fromHostID: hostID))
        #expect(screen.route == .throughSSH(hostID: hostID))
        #expect(screen.address == "10.0.0.2")
        #expect(screen.port == 5901)
        #expect(screen.hasPassword)
        #expect(screen.name.contains("Build box"))

        // Through SSH with no target: the server's own desktop, which is what the old
        // code dialled when `targetHost` was unset.
        var ownDesktop = throughSSH
        ownDesktop.vnc = Host.VNCSettings(port: 5900, viaSSH: true, targetHost: nil, hasPassword: false)
        #expect(ScreenMigration.screen(fromLegacy: ownDesktop)?.address == "127.0.0.1")

        // Direct: the old code dialled the SSH connection's own hostname.
        var direct = throughSSH
        direct.vnc = Host.VNCSettings(port: 5900, viaSSH: false, targetHost: nil, hasPassword: false)
        let migrated = try! #require(ScreenMigration.screen(fromLegacy: direct))
        #expect(migrated.route == .direct)
        #expect(migrated.address == "build.example.com")

        var none = throughSSH
        none.vnc = nil
        #expect(ScreenMigration.screen(fromLegacy: none) == nil)
    }

    @Test("Migration moves the password, empties the connection, and running it twice changes nothing")
    @MainActor func migrationIsIdempotent() throws {
        let directory = try directory()
        let hosts = HostStore(directory: directory)
        let screens = ScreenStore(directory: directory)
        let vault = CredentialVault()
        let hostID = UUID()
        var host = Host(id: hostID, name: "Build box", hostname: "build.example.com", username: "me", credentials: [.password])
        host.vnc = Host.VNCSettings(port: 5901, viaSSH: true, targetHost: "10.0.0.2", hasPassword: true)
        hosts.add(host)
        try vault.storeLegacyVNCPassword("s3cret", hostID: hostID)
        defer {
            try? vault.deleteVNCPassword(hostID: hostID)
            try? vault.deleteVNCPassword(screenID: ScreenConnection.migratedID(fromHostID: hostID))
        }

        ScreenMigration.runAtLaunch(hosts: hosts, screens: screens, vault: vault, log: .disabled)

        #expect(screens.screens.count == 1)
        let screen = try #require(screens.screens.first)
        #expect(screen.address == "10.0.0.2")
        #expect(hosts.hosts.first?.vnc == nil, "the connection no longer carries a screen")
        #expect(try vault.loadVNCPassword(screenID: screen.id) == "s3cret", "the password came with it")
        #expect(!vault.hasVNCPassword(hostID: hostID), "and is no longer under the connection")

        // Again: nothing new, nothing lost.
        ScreenMigration.runAtLaunch(hosts: hosts, screens: screens, vault: vault, log: .disabled)
        #expect(screens.screens.count == 1)
        #expect(try vault.loadVNCPassword(screenID: screen.id) == "s3cret")
    }

    @Test("The store adds, updates, deletes with a tombstone, and refuses to insert the same screen twice")
    @MainActor func store() throws {
        let directory = try directory()
        let tombstones = SyncTombstones(directory: directory)
        let store = ScreenStore(directory: directory)
        store.tombstones = tombstones

        let screen = ScreenConnection(name: "Desk", address: "127.0.0.1", route: .direct)
        store.add(screen)
        #expect(store.screens.count == 1)
        #expect(store.screen(withID: screen.id)?.modifiedAt != nil, "a local change is stamped")

        #expect(store.insertIfAbsent(screen) == false, "the same id is not added twice")
        #expect(store.screens.count == 1)

        var edited = screen
        edited.name = "Desk upstairs"
        store.update(edited)
        #expect(store.screen(withID: screen.id)?.name == "Desk upstairs")

        // Reopened from disk, it is still there.
        let reopened = ScreenStore(directory: directory)
        #expect(reopened.screens.count == 1)

        store.remove(screen)
        #expect(store.screens.isEmpty)
        #expect(tombstones.all.contains { $0.key == SyncKey(kind: .screen, id: screen.id.uuidString) },
                "a deletion is remembered, or another device sends it straight back")
    }

    @Test("Screens through a connection can be found, so deleting it can say what it affects")
    @MainActor func screensThroughAHost() throws {
        let directory = try directory()
        let store = ScreenStore(directory: directory)
        let hostID = UUID()
        store.add(ScreenConnection(name: "A", address: "127.0.0.1", route: .throughSSH(hostID: hostID)))
        store.add(ScreenConnection(name: "B", address: "127.0.0.1", route: .direct))
        #expect(store.screens(throughHostID: hostID).map(\.name) == ["A"])
    }
}
