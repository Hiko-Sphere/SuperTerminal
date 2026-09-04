import Foundation
import Testing
@testable import STTerminal

/// Mouse reporting has to match what the program asked for exactly. Sending the wrong
/// encoding is worse than sending nothing, because the program reads the bytes as
/// keystrokes.
@Suite("Mouse reporting")
struct MouseReportingTests {
    private func modes(
        _ tracking: TerminalModes.MouseTracking,
        sgr: Bool = false
    ) -> TerminalModes {
        var modes = TerminalModes()
        modes.mouseTracking = tracking
        modes.sgrMouseEncoding = sgr
        return modes
    }

    @Test("Nothing is reported when the program did not ask")
    func offMeansSilent() {
        let event = TerminalMouseEvent(column: 3, row: 4, button: .left, action: .press)
        #expect(MouseReportEncoder.encode(event, modes: modes(.off)) == nil)
    }

    @Test("A click is reported in the legacy encoding with the 32 offset")
    func legacyPress() {
        let event = TerminalMouseEvent(column: 0, row: 0, button: .left, action: .press)
        let data = MouseReportEncoder.encode(event, modes: modes(.click))
        // ESC [ M, then button 0+32, column 1+32, row 1+32.
        #expect(data == Data([0x1B, 0x5B, 0x4D, 32, 33, 33]))
    }

    @Test("A legacy release does not say which button was let go")
    func legacyReleaseUsesButtonThree() {
        let event = TerminalMouseEvent(column: 0, row: 0, button: .left, action: .release)
        let data = MouseReportEncoder.encode(event, modes: modes(.click))
        #expect(data == Data([0x1B, 0x5B, 0x4D, 35, 33, 33]))
    }

    @Test("SGR keeps the button on release and marks it with a lowercase terminator")
    func sgrRelease() {
        let press = TerminalMouseEvent(column: 9, row: 4, button: .right, action: .press)
        #expect(
            MouseReportEncoder.encode(press, modes: modes(.click, sgr: true))
                == Data("\u{1B}[<2;10;5M".utf8)
        )

        let release = TerminalMouseEvent(column: 9, row: 4, button: .right, action: .release)
        #expect(
            MouseReportEncoder.encode(release, modes: modes(.click, sgr: true))
                == Data("\u{1B}[<2;10;5m".utf8)
        )
    }

    @Test("Modifiers are folded into the button field")
    func modifiers() {
        let event = TerminalMouseEvent(
            column: 0, row: 0, button: .left, action: .press,
            shift: true, alt: false, control: true
        )
        // 0 + shift(4) + control(16) = 20
        #expect(
            MouseReportEncoder.encode(event, modes: modes(.click, sgr: true))
                == Data("\u{1B}[<20;1;1M".utf8)
        )
    }

    @Test("Scroll wheel uses the wheel button codes")
    func scrollWheel() {
        let up = TerminalMouseEvent(column: 0, row: 0, button: .scrollUp, action: .press)
        #expect(
            MouseReportEncoder.encode(up, modes: modes(.click, sgr: true))
                == Data("\u{1B}[<64;1;1M".utf8)
        )
        let down = TerminalMouseEvent(column: 0, row: 0, button: .scrollDown, action: .press)
        #expect(
            MouseReportEncoder.encode(down, modes: modes(.click, sgr: true))
                == Data("\u{1B}[<65;1;1M".utf8)
        )
    }

    @Test("Drag is reported only from button-event tracking upwards")
    func dragRequiresButtonEventTracking() {
        let drag = TerminalMouseEvent(column: 2, row: 2, button: .left, action: .drag)
        #expect(MouseReportEncoder.encode(drag, modes: modes(.click)) == nil)
        #expect(MouseReportEncoder.encode(drag, modes: modes(.buttonEvent, sgr: true)) != nil)
    }

    @Test("Buttonless motion is reported only in any-event tracking")
    func motionRequiresAnyEventTracking() {
        let motion = TerminalMouseEvent(column: 2, row: 2, button: .none, action: .motion)
        #expect(MouseReportEncoder.encode(motion, modes: modes(.buttonEvent)) == nil)
        #expect(MouseReportEncoder.encode(motion, modes: modes(.anyEvent, sgr: true)) != nil)
    }

    @Test("Drag sets the motion bit")
    func dragSetsMotionBit() {
        let drag = TerminalMouseEvent(column: 0, row: 0, button: .left, action: .drag)
        // 0 + motion(32) = 32
        #expect(
            MouseReportEncoder.encode(drag, modes: modes(.buttonEvent, sgr: true))
                == Data("\u{1B}[<32;1;1M".utf8)
        )
    }

    @Test("The legacy encoding reports nothing past its coordinate ceiling")
    func legacyCoordinateCeiling() {
        let far = TerminalMouseEvent(column: 300, row: 4, button: .left, action: .press)
        // A wrapped coordinate would report a click somewhere the user did not touch,
        // which is worse than the program seeing no event at all.
        #expect(MouseReportEncoder.encode(far, modes: modes(.click)) == nil)
        // SGR has no such limit, which is exactly why programs ask for it.
        #expect(
            MouseReportEncoder.encode(far, modes: modes(.click, sgr: true))
                == Data("\u{1B}[<0;301;5M".utf8)
        )
    }
}
