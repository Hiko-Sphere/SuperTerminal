import Testing
@testable import STTerminal

/// The parser's contract is that *no* byte sequence can wedge it. These tests cover the
/// well-formed cases and, just as importantly, the malformed ones — a terminal spends a
/// lot of its life recovering from truncated output.
@Suite("Terminal parser")
struct TerminalParserTests {
    private func actions(_ input: String) -> [TerminalAction] {
        actions(Array(input.utf8))
    }

    private func actions(_ bytes: [UInt8]) -> [TerminalAction] {
        var parser = TerminalParser()
        var result: [TerminalAction] = []
        parser.parse(bytes) { result.append($0) }
        parser.flush { result.append($0) }
        return result
    }

    @Test("Plain text becomes print actions")
    func plainText() {
        #expect(actions("hi") == [.print("h"), .print("i")])
    }

    @Test("C0 controls are executed, not printed")
    func controls() {
        #expect(actions("a\r\n") == [.print("a"), .execute(0x0D), .execute(0x0A)])
    }

    @Test("A CSI sequence is parsed into parameters and a final byte")
    func csiParameters() {
        let parsed = actions("\u{1B}[12;34H")
        #expect(parsed == [.csi(CSISequence(parameters: [12, 34], subParameters: [[], []], final: 0x48))])
    }

    @Test("An omitted parameter stays distinguishable from an explicit zero")
    func omittedParameters() {
        guard case let .csi(sequence)? = actions("\u{1B}[;5H").first else {
            Issue.record("expected a CSI action")
            return
        }
        // `CSI ; 5 H` means "default row, column 5" — collapsing the omission to 0 would
        // move the cursor to the wrong row.
        #expect(sequence.parameters == [nil, 5])
        #expect(sequence.parameter(0, default: 1) == 1)
        #expect(sequence.parameter(1, default: 1) == 5)
    }

    @Test("Private markers are captured")
    func privateMarker() {
        guard case let .csi(sequence)? = actions("\u{1B}[?25l").first else {
            Issue.record("expected a CSI action")
            return
        }
        #expect(sequence.privateMarker == UInt8(ascii: "?"))
        #expect(sequence.parameters == [25])
        #expect(sequence.final == UInt8(ascii: "l"))
    }

    @Test("Colon sub-parameters are kept separate from semicolon parameters")
    func subParameters() {
        guard case let .csi(sequence)? = actions("\u{1B}[38:2::17:34:51m").first else {
            Issue.record("expected a CSI action")
            return
        }
        #expect(sequence.parameters == [38])
        #expect(sequence.subParameters.first == [2, nil, 17, 34, 51])
    }

    @Test("An OSC string terminated by BEL is dispatched")
    func oscWithBEL() {
        #expect(actions("\u{1B}]0;my title\u{07}") == [.osc(command: 0, payload: "my title")])
    }

    @Test("An OSC string terminated by ST is dispatched")
    func oscWithST() {
        #expect(actions("\u{1B}]2;other\u{1B}\\") == [
            .osc(command: 2, payload: "other"),
            .escape(intermediates: [], final: UInt8(ascii: "\\")),
        ])
    }

    @Test("A truncated escape sequence does not swallow the text after it")
    func truncatedSequenceRecovers() {
        // ESC [ 1 ; then a new ESC: the first sequence is abandoned, not left pending.
        let parsed = actions("\u{1B}[1;\u{1B}[Hok")
        #expect(parsed.contains(.csi(CSISequence(parameters: [], subParameters: [], final: 0x48))))
        #expect(parsed.suffix(2) == [.print("o"), .print("k")])
    }

    @Test("CAN aborts a sequence in progress")
    func cancelAbortsSequence() {
        let parsed = actions([0x1B, 0x5B, 0x31, 0x18, 0x41]) // ESC [ 1 CAN A
        #expect(parsed == [.execute(0x18), .print("A")])
    }

    @Test("An absurd parameter value saturates instead of overflowing")
    func hugeParameterSaturates() {
        guard case let .csi(sequence)? = actions("\u{1B}[99999999999999999999H").first else {
            Issue.record("expected a CSI action")
            return
        }
        #expect(sequence.parameter(0, default: 1) <= 655_360)
    }

    @Test("An over-long OSC string is dropped rather than buffered")
    func oversizedOSCIsDropped() {
        let payload = String(repeating: "A", count: TerminalParser.maximumStringLength + 100)
        #expect(actions("\u{1B}]0;\(payload)\u{07}").isEmpty)
    }

    @Test("Multi-byte UTF-8 is decoded across buffer boundaries")
    func utf8AcrossChunks() {
        var parser = TerminalParser()
        var result: [TerminalAction] = []
        // "中" is E4 B8 AD; deliver it one byte per call, as a slow network would.
        for byte in Array("中".utf8) {
            parser.parse([byte]) { result.append($0) }
        }
        parser.flush { result.append($0) }
        #expect(result == [.print("中")])
    }

    @Test("Invalid UTF-8 becomes a replacement character without losing what follows")
    func invalidUTF8Recovers() {
        let parsed = actions([0xE4, 0xB8, 0x41]) // truncated 3-byte sequence, then "A"
        #expect(parsed == [.print("\u{FFFD}"), .print("A")])
    }

    @Test("Combining marks are joined into a single grapheme cluster")
    func combiningMarksCluster() {
        #expect(actions("e\u{0301}x") == [.print("e\u{0301}"), .print("x")])
    }
}
