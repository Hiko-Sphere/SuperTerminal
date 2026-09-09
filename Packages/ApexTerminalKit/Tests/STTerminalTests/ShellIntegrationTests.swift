import Foundation
import Testing

@testable import STTerminal

/// OSC 7, 52 and 133 (D-062).
///
/// These three are what turns a terminal from something that draws bytes into something
/// that knows what is happening in it: where the shell is, what the user typed, whether it
/// worked. OSC 52 is the odd one out — it is a remote host reaching for a local resource,
/// and the emulator's job there is to *report* rather than to act.
@Suite("Shell integration")
struct ShellIntegrationTests {
    private func feed(_ text: String) -> (TerminalEmulator, [TerminalEvent]) {
        var emulator = TerminalEmulator(columns: 80, rows: 24)
        let events = emulator.feed(Array(text.utf8))
        return (emulator, events)
    }

    @Test("OSC 7 reports where the shell is, decoded")
    func reportsWorkingDirectory() {
        let (emulator, events) = feed("\u{1B}]7;file://build.example.com/home/deploy/my%20project\u{07}")
        #expect(emulator.workingDirectory == "/home/deploy/my project", "percent-encoding is undone")
        #expect(events.contains(.workingDirectory("/home/deploy/my project")))
    }

    @Test("The host in an OSC 7 URL is ignored rather than checked")
    func ignoresTheHostPart() {
        // A shell writes its own hostname there, and it disagrees with what the client
        // thinks it connected to on every jump host and in every container. The path is
        // used to label a session and to open a pane in the same place — never to decide
        // anything about trust — so a mismatch is not a reason to throw it away.
        let (emulator, _) = feed("\u{1B}]7;file://something-else/var/log\u{07}")
        #expect(emulator.workingDirectory == "/var/log")
    }

    @Test("A working directory that is not a file URL, or carries control characters, is refused",
          arguments: [
              "\u{1B}]7;http://example.com/tmp\u{07}",
              "\u{1B}]7;/tmp\u{07}",
              "\u{1B}]7;file:///tmp/\u{01}evil\u{07}",
          ])
    func refusesBadWorkingDirectories(sequence: String) {
        let (emulator, events) = feed(sequence)
        #expect(emulator.workingDirectory == "")
        #expect(!events.contains { if case .workingDirectory = $0 { return true }; return false })
    }

    @Test("OSC 133 marks a prompt, a command, its output and how it ended")
    func reportsShellMarks() {
        let (_, events) = feed("""
        \u{1B}]133;A\u{07}deploy@web:~$ \u{1B}]133;B\u{07}uptime\r\n\u{1B}]133;C\u{07}up 3 days\r\n\u{1B}]133;D;0\u{07}
        """)
        #expect(events.contains(.shellIntegration(.promptStart)))
        #expect(events.contains(.shellIntegration(.commandStart)))
        #expect(events.contains(.shellIntegration(.outputStart)))
        #expect(events.contains(.shellIntegration(.commandFinished(exitCode: 0))))
    }

    @Test("A command that ended without a status is still an ending")
    func reportsFinishWithoutAStatus() {
        // `OSC 133 ; D ST` is what a shell sends when it has nothing to report, and a
        // client that required the status would miss the end of every such command.
        let (_, events) = feed("\u{1B}]133;D\u{07}")
        #expect(events.contains(.shellIntegration(.commandFinished(exitCode: nil))))
        let (_, failed) = feed("\u{1B}]133;D;127\u{07}")
        #expect(failed.contains(.shellIntegration(.commandFinished(exitCode: 127))))
    }

    @Test("OSC 52 reports a clipboard write rather than performing one")
    func reportsClipboardWrites() {
        let encoded = Data("hello".utf8).base64EncodedString()
        let (_, events) = feed("\u{1B}]52;c;\(encoded)\u{07}")
        #expect(events.contains(.clipboardWriteRequested(Data("hello".utf8))))
    }

    @Test("A clipboard *read* is refused and not even reported")
    func refusesClipboardReads() {
        // `OSC 52 ; c ; ?` asks the terminal to send back what is on the clipboard.
        // Answering hands whatever was last copied — a password, a token — to whatever is
        // running on the far side. Several terminals disable OSC 52 entirely for this;
        // here the write half is kept, behind the user's permission, and the read half is
        // refused outright.
        let (_, events) = feed("\u{1B}]52;c;?\u{07}")
        #expect(events.isEmpty)
        // And nothing is written back to the host either, which is what a "report" would
        // have to be here.
        #expect(!events.contains { if case .respond = $0 { return true }; return false })
    }

    @Test("A clipboard payload that is not base64, or is enormous, is dropped")
    func refusesBadClipboardPayloads() {
        let (_, notBase64) = feed("\u{1B}]52;c;!!!!not base64!!!!\u{07}")
        #expect(!notBase64.contains { if case .clipboardWriteRequested = $0 { return true }; return false })

        // A clipboard is not a file transfer: 64 KiB is more than any real copy.
        let huge = String(repeating: "A", count: 200_000)
        let (_, oversized) = feed("\u{1B}]52;c;\(huge)\u{07}")
        #expect(!oversized.contains { if case .clipboardWriteRequested = $0 { return true }; return false })
    }
}
