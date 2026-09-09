import Foundation
import Testing

@testable import STTmux

/// The control-mode parser, against transcripts taken from a real tmux 3.3a.
///
/// Every transcript below was produced by driving a real server and copying what came back,
/// not written from the manual. That matters more than usual here: three of the shapes the
/// documentation implies are wrong, and each of them is a defect a hand-written fixture
/// would have hidden — `%error` closes a block whose body holds the message, a command's
/// reply can itself begin with `%`, and output is escaped in octal *including* the
/// backslash, so a literal backslash never appears in the stream.
@Suite("tmux control-mode parser")
struct TmuxControlParserTests {
    private func parse(_ transcript: String) -> [TmuxControlMessage] {
        var parser = TmuxControlParser()
        return (try? parser.consume(Array(transcript.utf8))) ?? []
    }

    /// Attaching, listing windows, splitting, typing, listing panes, killing the session —
    /// captured from `tmux -C new-session` in a container.
    private static let transcript = """
    %begin 1788940851 259 0
    %end 1788940851 259 0
    %window-add @0
    %sessions-changed
    %session-changed $0 0
    %output %0 \\033[?2004hroot@fa80335afa4b:/#\u{20}
    %begin 1788940852 265 1
    0: bash* (1 panes) [80x24] [layout b25d,80x24,0,0,0] @0 (active)
    %end 1788940852 265 1
    %window-pane-changed @0 %1
    %layout-change @0 c195,80x24,0,0[80x12,0,0,0,80x11,0,13,1] c195,80x24,0,0[80x12,0,0,0,80x11,0,13,1] *
    %output %0 hello\\015\\012\\033[?2004l\\015
    %exit

    """

    @Test("A whole session's transcript parses into the messages it describes")
    func parsesARealTranscript() {
        let messages = parse(Self.transcript)

        #expect(messages.count == 13)
        #expect(messages[0] == .commandBegin(number: 259, time: 1_788_940_851, flags: 0))
        #expect(messages[1] == .commandEnd(number: 259, failed: false))
        #expect(messages[2] == .notification(.windowAdd(window: TmuxWindowID(0))))
        #expect(messages[3] == .notification(.sessionsChanged))
        #expect(messages[4] == .notification(.sessionChanged(session: TmuxSessionID(0), name: "0")))

        guard case let .notification(.output(pane, bytes)) = messages[5] else {
            Issue.record("expected output, got \(messages[5])")
            return
        }
        #expect(pane == TmuxPaneID(0))
        #expect(String(decoding: bytes, as: UTF8.self) == "\u{1B}[?2004hroot@fa80335afa4b:/# ")

        // The reply to `list-windows`, which is a plain line between the guards.
        #expect(messages[6] == .commandBegin(number: 265, time: 1_788_940_852, flags: 1))
        #expect(messages[7] == .commandOutput("0: bash* (1 panes) [80x24] [layout b25d,80x24,0,0,0] @0 (active)"))
        #expect(messages[8] == .commandEnd(number: 265, failed: false))

        #expect(messages[9] == .notification(.windowPaneChanged(window: TmuxWindowID(0), pane: TmuxPaneID(1))))
        #expect(messages[10] == .notification(.layoutChange(
            window: TmuxWindowID(0),
            layout: "c195,80x24,0,0[80x12,0,0,0,80x11,0,13,1]",
            visibleLayout: "c195,80x24,0,0[80x12,0,0,0,80x11,0,13,1]",
            flags: "*"
        )))

        guard case let .notification(.output(_, echo)) = messages[11] else {
            Issue.record("expected the echoed line")
            return
        }
        #expect(String(decoding: echo, as: UTF8.self) == "hello\r\n\u{1B}[?2004l\r")
        #expect(messages[12] == .notification(.exit(reason: nil)))
    }

    @Test("A reply that begins with % is the reply, not a notification")
    func repliesWinOverNotifications() {
        // `display-message -p '#{pane_id}'` prints `%0`. A parser that dispatched on the
        // leading `%` before asking whether it was inside a block would lose the answer and
        // invent a notification — measured against a real server, which is where this
        // transcript is from.
        let messages = parse("""
        %begin 1788941108 265 1
        %0
        %end 1788941108 265 1

        """)
        #expect(messages == [
            .commandBegin(number: 265, time: 1_788_941_108, flags: 1),
            .commandOutput("%0"),
            .commandEnd(number: 265, failed: false),
        ])
    }

    @Test("An error closes the block, and the message is inside it")
    func errorsCarryTheirMessage() {
        let messages = parse("""
        %begin 1788940872 265 1
        parse error: unknown command: not-a-command
        %error 1788940872 265 1

        """)
        #expect(messages[1] == .commandOutput("parse error: unknown command: not-a-command"))
        #expect(messages[2] == .commandEnd(number: 265, failed: true))
    }

    @Test("Output is unescaped octal, and only octal")
    func unescapesOutput() {
        // `\\134` is a backslash: tmux escapes its own escape character, so a bare
        // backslash is not part of the protocol.
        let messages = parse("%output %1 printf %s a\\134b\\015\\012\n")
        guard case let .notification(.output(_, bytes)) = messages[0] else {
            Issue.record("expected output")
            return
        }
        #expect(String(decoding: bytes, as: UTF8.self) == "printf %s a\\b\r\n")
    }

    @Test("UTF-8 in a pane's output is passed through, not escaped")
    func passesThroughUTF8() {
        // Measured: tmux escapes non-printable ASCII and the backslash; the bytes of 中文
        // arrive as themselves. Decoding the line as text and re-encoding it would work
        // here and corrupt a byte sequence that is not valid UTF-8, which is why the
        // payload is carried as bytes.
        let messages = parse("%output %0 中文é\n")
        guard case let .notification(.output(_, bytes)) = messages[0] else {
            Issue.record("expected output")
            return
        }
        #expect(bytes == Array("中文é".utf8))
    }

    @Test("An invalid escape is passed through rather than eaten")
    func keepsInvalidEscapes() {
        // \\9 is not octal, and \\40 is too short. Neither is something tmux sends; if one
        // arrives, dropping it would silently corrupt a terminal, so it is kept.
        let messages = parse("%output %0 a\\9b\\40\n")
        guard case let .notification(.output(_, bytes)) = messages[0] else {
            Issue.record("expected output")
            return
        }
        #expect(String(decoding: bytes, as: UTF8.self) == "a\\9b\\40")
    }

    @Test("The same bytes parse the same however they are chopped up")
    func isIncremental() {
        let whole = parse(Self.transcript)
        var parser = TmuxControlParser()
        var byByte: [TmuxControlMessage] = []
        for byte in Array(Self.transcript.utf8) {
            byByte += (try? parser.consume([byte])) ?? []
        }
        // A network hands over whatever size it likes, including one byte at a time.
        #expect(byByte == whole)
    }

    @Test("Extended output carries its age")
    func parsesExtendedOutput() {
        let messages = parse("%extended-output %0 1 : \\033[?2004hready\n")
        #expect(messages == [.notification(.extendedOutput(
            pane: TmuxPaneID(0),
            age: 1,
            bytes: Array("\u{1B}[?2004hready".utf8)
        ))])
    }

    @Test("Every notification a real session sends is recognised")
    func recognisesTheRest() {
        let messages = parse("""
        %window-close @2
        %window-renamed @0 banana
        %unlinked-window-add @3
        %session-window-changed $0 @1
        %session-renamed work
        %client-session-changed client-1 $0 work
        %client-detached client-1
        %pane-mode-changed %4
        %pause %4
        %continue %4
        %subscription-changed name $0 @0 0 %0 : value
        %message something happened
        %exit server exited unexpectedly

        """)
        #expect(messages == [
            .notification(.windowClose(window: TmuxWindowID(2))),
            .notification(.windowRenamed(window: TmuxWindowID(0), name: "banana")),
            .notification(.unlinkedWindowAdd(window: TmuxWindowID(3))),
            .notification(.sessionWindowChanged(session: TmuxSessionID(0), window: TmuxWindowID(1))),
            .notification(.sessionRenamed(name: "work")),
            .notification(.clientSessionChanged(client: "client-1", session: TmuxSessionID(0), name: "work")),
            .notification(.clientDetached(client: "client-1")),
            .notification(.paneModeChanged(pane: TmuxPaneID(4))),
            .notification(.pause(pane: TmuxPaneID(4))),
            .notification(.resume(pane: TmuxPaneID(4))),
            .notification(.subscriptionChanged(name: "name", rest: "$0 @0 0 %0 : value")),
            .notification(.message("something happened")),
            .notification(.exit(reason: "server exited unexpectedly")),
        ])
    }

    @Test("A notification this version does not know is kept, not dropped")
    func keepsUnknownNotifications() {
        // tmux adds these between releases. A client that discards what it does not
        // recognise cannot be debugged from a log by anyone.
        let messages = parse("%something-new @0 with arguments\n")
        #expect(messages == [.notification(.unrecognised(name: "something-new", arguments: "@0 with arguments"))])
    }

    @Test("A line that never ends cannot grow without bound")
    func refusesAnEndlessLine() {
        var parser = TmuxControlParser()
        let chunk = [UInt8](repeating: 0x41, count: 1024 * 1024)
        #expect(throws: TmuxControlParser.ParseError.self) {
            for _ in 0 ..< 8 { _ = try parser.consume(chunk) }
        }
    }
}
