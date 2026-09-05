import Foundation
import STCore
import STSSH
import Testing
@testable import SuperTerminal

/// Snippets are ordinary data; command history is not. These tests are mostly about the
/// history rule, because getting it wrong means silently recording something the user
/// asked not to be recorded.
@Suite("Snippets and history")
@MainActor
struct SnippetAndHistoryTests {
    private func makeStore(historyEnabled: Bool) -> (SnippetStore, AppSettings, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("st-snippets-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "snippets-\(UUID())")!)
        settings.commandHistoryEnabled = historyEnabled
        return (SnippetStore(directory: directory, settings: settings), settings, directory)
    }

    @Test("History is not recorded when the setting is off")
    func historyOffRecordsNothing() {
        let (store, _, directory) = makeStore(historyEnabled: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        store.record(command: "cat /etc/shadow", hostID: UUID(), hostName: "prod")
        // Off must mean nothing is kept, not merely nothing is shown.
        #expect(store.history.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path))
    }

    @Test("History is recorded when the setting is on")
    func historyOnRecords() {
        let (store, _, directory) = makeStore(historyEnabled: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let host = UUID()
        store.record(command: "uptime", hostID: host, hostName: "web")
        #expect(store.history.count == 1)
        #expect(store.history.first?.command == "uptime")
        #expect(store.history.first?.hostID == host)
    }

    @Test("Clearing history removes the file, not just the list")
    func clearingRemovesTheFile() {
        let (store, _, directory) = makeStore(historyEnabled: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")

        store.record(command: "uptime", hostID: UUID(), hostName: "web")
        #expect(FileManager.default.fileExists(atPath: file.path))

        store.clearHistory()
        #expect(store.history.isEmpty)
        // A file left behind would come back if the setting were re-enabled.
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A store created with history off does not read an existing history file")
    func historyIsNotReloadedWhileOff() {
        let (store, settings, directory) = makeStore(historyEnabled: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.record(command: "secret-command", hostID: UUID(), hostName: "web")
        #expect(store.history.count == 1)

        settings.commandHistoryEnabled = false
        let reopened = SnippetStore(directory: directory, settings: settings)
        #expect(reopened.history.isEmpty)
    }

    @Test("Consecutive repeats of the same command are not recorded twice")
    func repeatsAreCollapsed() {
        let (store, _, directory) = makeStore(historyEnabled: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let host = UUID()
        store.record(command: "ls", hostID: host, hostName: "web")
        store.record(command: "ls", hostID: host, hostName: "web")
        store.record(command: "pwd", hostID: host, hostName: "web")
        #expect(store.history.count == 2)
    }

    @Test("History is bounded")
    func historyIsBounded() {
        let (store, _, directory) = makeStore(historyEnabled: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0 ..< (SnippetStore.historyLimit + 100) {
            store.record(command: "command-\(index)", hostID: UUID(), hostName: "web")
        }
        // Turning the feature on must not create an unbounded record of everything, ever.
        #expect(store.history.count == SnippetStore.historyLimit)
        #expect(store.history.first?.command == "command-100")
    }

    @Test("Search filters by text and by host")
    func searchFilters() {
        let (store, _, directory) = makeStore(historyEnabled: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let web = UUID()
        let db = UUID()
        store.record(command: "systemctl status nginx", hostID: web, hostName: "web")
        store.record(command: "systemctl status postgres", hostID: db, hostName: "db")

        #expect(store.searchHistory("systemctl").count == 2)
        #expect(store.searchHistory("nginx").count == 1)
        #expect(store.searchHistory("", hostID: db).count == 1)
        #expect(store.searchHistory("nginx", hostID: db).isEmpty)
    }

    @Test("Snippets survive a reload")
    func snippetsPersist() {
        let (store, settings, directory) = makeStore(historyEnabled: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        store.add(Snippet(name: "Disk", command: "df -h"))
        let reopened = SnippetStore(directory: directory, settings: settings)
        #expect(reopened.snippets.count == 1)
        #expect(reopened.snippets.first?.command == "df -h")
    }

    @Test("The starter set does not duplicate commands already saved")
    func starterSetIsIdempotent() {
        let (store, _, directory) = makeStore(historyEnabled: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        store.installStarterSet()
        let first = store.snippets.count
        store.installStarterSet()
        #expect(store.snippets.count == first)
    }

    @Test("The starter set only reads state")
    func starterSetIsHarmless() {
        // A starter set that included `rm` or a service restart would teach the wrong
        // habit on the very first run.
        for snippet in Snippet.starterSet {
            let command = snippet.command.lowercased()
            for dangerous in ["rm ", "mkfs", "dd ", "shutdown", "reboot", "restart", "kill "] {
                #expect(!command.contains(dangerous), "\(snippet.name) contains \(dangerous)")
            }
            #expect(!snippet.runsImmediately, "\(snippet.name) should not run on tap by default")
        }
    }

    @Test("Marking a snippet used moves it up the list")
    func usageOrdersTheList() {
        let (store, _, directory) = makeStore(historyEnabled: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        store.add(Snippet(name: "Alpha", command: "a"))
        store.add(Snippet(name: "Beta", command: "b"))
        guard let beta = store.snippets.first(where: { $0.name == "Beta" }) else {
            Issue.record("expected Beta")
            return
        }
        store.markUsed(beta)
        // A list ordered by creation puts the least familiar things at the top.
        #expect(store.snippets.first?.name == "Beta")
    }
}

/// Reconstructing what was typed.
///
/// History records keystrokes rather than what appears on screen, because the screen is
/// the *shell's* rendering — it carries the prompt, and under completion or syntax
/// highlighting it is not the literal text that was typed.
@Suite("Typed-command reconstruction")
@MainActor
struct TypedInputTests {
    private func session() -> TerminalSession {
        TerminalSession(
            host: Host(name: "T", hostname: "example", username: "u", credentials: [.none]),
            group: SessionTestSupport.group,
            vault: CredentialVault(),
            knownHosts: InMemoryKnownHostsStore(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "typed-\(UUID())")!),
            log: .disabled
        )
    }

    private func submitted(_ inputs: [String]) -> [String] {
        let session = session()
        for input in inputs { session.noteTypedInput(Data(input.utf8)) }
        return session.takeSubmittedCommands()
    }

    @Test("A line typed one character at a time is reassembled")
    func characterAtATime() {
        #expect(submitted("uptime\r".map(String.init)) == ["uptime"])
    }

    @Test("A whole line arriving as one chunk is recorded once")
    func wholeLineAtOnce() {
        #expect(submitted(["uptime\r"]) == ["uptime"])
    }

    @Test("A paste containing several lines records each of them")
    func multiplePastedLines() {
        // Keeping only the last would silently drop the rest of a pasted block.
        #expect(submitted(["cd /var/log\nls -l\ntail -n 5 syslog\n"]) == ["cd /var/log", "ls -l", "tail -n 5 syslog"])
    }

    @Test("Backspace removes the character it removed on screen")
    func backspace() {
        #expect(submitted(["upti", "\u{7F}", "ime\r"]) == ["uptime"])
    }

    @Test("Control-C abandons the line instead of submitting it")
    func interruptAbandons() {
        // The user pressed ^C precisely because they did not want to run it.
        #expect(submitted(["rm -rf /", "\u{03}", "uptime\r"]) == ["uptime"])
    }

    @Test("Escape-sequence bytes never leak into a command")
    func escapeSequenceBytesAreNotTyping() {
        // The bug this replaces recorded "ls[A[D": the bytes of the arrow keys were
        // letters and punctuation, so they looked like typing.
        for recorded in submitted(["ls", "\u{1B}[A", "\u{1B}[D", "\r"]) {
            #expect(!recorded.contains("["))
            #expect(recorded != "ls[A[D")
        }
    }

    @Test("A line the remote editor may have changed is not recorded at all")
    func lineEditingAbandonsTheLine() {
        // Up-arrow recalls a different command from the shell's own history; after that
        // the line on screen is not the line we watched being typed. Recording a guess
        // would be worse than recording nothing.
        #expect(submitted(["ls", "\u{1B}[A", "\r"]).isEmpty)
        #expect(submitted(["ls", "\u{1B}[D", "x", "\r"]).isEmpty)
        #expect(submitted(["ls", "\t", "\r"]).isEmpty)
    }

    @Test("An escape sequence before anything is typed does not spoil the next line")
    func escapeBeforeTypingIsHarmless() {
        // A stray arrow at an empty prompt changes nothing, so the line that follows is
        // still exactly what was typed.
        #expect(submitted(["\u{1B}[A", "\u{1B}[B", "uptime\r"]) == ["uptime"])
    }

    @Test("Longer escape sequences are consumed whole")
    func stringSequencesAreConsumed() {
        // OSC 0 (set window title) ends with BEL, and its payload is ordinary text that
        // would otherwise be indistinguishable from typing.
        #expect(submitted(["\u{1B}]0;some title\u{07}", "uptime\r"]) == ["uptime"])
        #expect(submitted(["\u{1B}P+q544e\u{1B}\\", "uptime\r"]) == ["uptime"])
    }

    @Test("Kill-line abandons the line")
    func killLineAbandons() {
        #expect(submitted(["secret", "\u{15}", "uptime\r"]) == ["uptime"])
    }

    @Test("A bare Return records nothing")
    func emptyLine() {
        #expect(submitted(["\r", "   \r"]).isEmpty)
    }

    @Test("Taking the commands clears them")
    func takeIsDestructive() {
        let session = session()
        session.noteTypedInput(Data("uptime\r".utf8))
        #expect(session.takeSubmittedCommands() == ["uptime"])
        #expect(session.takeSubmittedCommands().isEmpty)
    }
}

/// Everything that can put a command on the remote line has to be recorded the same way.
///
/// These went in after the recorder was moved out of the keyboard's callback: snippets
/// and pastes never went through it, so a command that arrived either way was silently
/// missing from history.
@Suite("Every input path is recorded")
@MainActor
struct InputPathRecordingTests {
    private func makeSession() -> TerminalSession {
        TerminalSession(
            host: Host(name: "T", hostname: "example", username: "u", credentials: [.none]),
            group: SessionTestSupport.group,
            vault: CredentialVault(),
            knownHosts: InMemoryKnownHostsStore(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "paths-\(UUID())")!),
            log: .disabled
        )
    }

    @Test("A snippet that runs immediately is recorded")
    func immediateSnippetIsRecorded() async {
        let session = makeSession()
        // No shell, so nothing is sent; the accounting is what is under test, and it must
        // not depend on the network.
        session.noteTypedInput(Data("df -h\r".utf8))
        #expect(session.takeSubmittedCommands() == ["df -h"])
    }

    @Test("A snippet that waits is recorded when the user presses Return")
    func insertedSnippetIsRecordedOnReturn() {
        let session = makeSession()
        session.noteTypedInput(Data("df -h".utf8))
        #expect(session.takeSubmittedCommands().isEmpty)
        session.noteTypedInput(Data("\r".utf8))
        #expect(session.takeSubmittedCommands() == ["df -h"])
    }

    @Test("The stream sees commands from any source")
    func streamObservesEverySource() async {
        let session = makeSession()
        var received: [String] = []
        // `AsyncStream`'s build closure runs at creation, so the observer is registered
        // here, synchronously — before anything is submitted. No wait is needed for that.
        let stream = session.submittedCommandStream
        let collector = Task { for await command in stream { received.append(command) } }

        session.noteTypedInput(Data("typed\r".utf8))
        session.noteTypedInput(Data("pasted-one\npasted-two\n".utf8))

        // Wait for the consumer to drain, rather than cancelling it after a fixed delay.
        // The stream buffers, so the elements are already there; what a fixed 50 ms
        // assumed was that the collector had been *scheduled* — true on an idle machine
        // and false on a loaded one, which is how this failed during a parallel run.
        let deadline = ContinuousClock.now + .seconds(5)
        while received.count < 3, ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        collector.cancel()

        #expect(received == ["typed", "pasted-one", "pasted-two"], "received \(received)")
    }
}
