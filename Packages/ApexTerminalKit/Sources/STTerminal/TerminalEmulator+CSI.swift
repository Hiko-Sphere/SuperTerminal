import Foundation

extension TerminalEmulator {
    mutating func applyCSI(_ sequence: CSISequence, emit: (TerminalEvent) -> Void) {
        if sequence.privateMarker != nil {
            applyPrivateCSI(sequence, emit: emit)
            return
        }
        // Intermediates select a different meaning for the same final byte; `CSI Ps SP q`
        // (DECSCUSR) is the one that matters in practice.
        if sequence.intermediates == [0x20], sequence.final == 0x71 {
            applyCursorStyle(sequence)
            return
        }
        guard sequence.intermediates.isEmpty else { return }

        switch sequence.final {
        case 0x41: // A — CUU
            withActiveScreenPublic { $0.moveCursorRelative(rows: -sequence.parameter(0, default: 1), columns: 0) }
        case 0x42: // B — CUD
            withActiveScreenPublic { $0.moveCursorRelative(rows: sequence.parameter(0, default: 1), columns: 0) }
        case 0x43: // C — CUF
            withActiveScreenPublic { $0.moveCursorRelative(rows: 0, columns: sequence.parameter(0, default: 1)) }
        case 0x44: // D — CUB
            withActiveScreenPublic { $0.moveCursorRelative(rows: 0, columns: -sequence.parameter(0, default: 1)) }
        case 0x45: // E — CNL
            withActiveScreenPublic {
                $0.moveCursor(row: $0.cursor.row + sequence.parameter(0, default: 1), column: 0)
            }
        case 0x46: // F — CPL
            withActiveScreenPublic {
                $0.moveCursor(row: $0.cursor.row - sequence.parameter(0, default: 1), column: 0)
            }
        case 0x47, 0x60: // G, ` — CHA / HPA
            withActiveScreenPublic {
                $0.moveCursor(row: $0.cursor.row, column: sequence.parameter(0, default: 1) - 1)
            }
        case 0x48, 0x66: // H, f — CUP / HVP
            let row = sequence.parameter(0, default: 1) - 1
            let column = sequence.parameter(1, default: 1) - 1
            let origin = modes.originMode ? activeScreen.scrollTop : 0
            withActiveScreenPublic { $0.moveCursor(row: origin + row, column: column) }
        case 0x49: // I — CHT
            for _ in 0 ..< max(1, sequence.parameter(0, default: 1)) { tabForward() }
        case 0x4A: // J — ED
            withActiveScreenPublic { $0.eraseInDisplay(mode: sequence.parameter(0, default: 0)) }
        case 0x4B: // K — EL
            withActiveScreenPublic { $0.eraseInLine(mode: sequence.parameter(0, default: 0)) }
        case 0x4C: // L — IL
            withActiveScreenPublic { $0.insertLines(sequence.parameter(0, default: 1)) }
        case 0x4D: // M — DL
            withActiveScreenPublic { $0.deleteLines(sequence.parameter(0, default: 1)) }
        case 0x50: // P — DCH
            withActiveScreenPublic { $0.deleteCharacters(sequence.parameter(0, default: 1)) }
        case 0x53: // S — SU
            withActiveScreenPublic { $0.scrollUp(sequence.parameter(0, default: 1)) }
        case 0x54: // T — SD
            withActiveScreenPublic { $0.scrollDown(sequence.parameter(0, default: 1)) }
        case 0x58: // X — ECH
            withActiveScreenPublic { $0.eraseCharacters(sequence.parameter(0, default: 1)) }
        case 0x5A: // Z — CBT
            for _ in 0 ..< max(1, sequence.parameter(0, default: 1)) { tabBackward() }
        case 0x40: // @ — ICH
            withActiveScreenPublic { $0.insertCharacters(sequence.parameter(0, default: 1)) }
        case 0x64: // d — VPA
            withActiveScreenPublic {
                $0.moveCursor(row: sequence.parameter(0, default: 1) - 1, column: $0.cursor.column)
            }
        case 0x6D: // m — SGR
            applySGR(sequence)
        case 0x6E: // n — DSR
            deviceStatusReport(sequence, emit: emit)
        case 0x63: // c — DA
            // Identify as a VT220 with no optional extensions. Programs use this to
            // decide which capabilities to attempt; claiming more than is implemented
            // is how a terminal ends up drawing garbage.
            emit(.respond(Data("\u{1B}[?62;c".utf8)))
        case 0x72: // r — DECSTBM
            let top = sequence.parameter(0, default: 1) - 1
            let bottom = sequence.parameter(1, default: activeScreen.rows) - 1
            withActiveScreenPublic {
                $0.setScrollRegion(top: top, bottom: bottom)
                $0.moveCursor(row: top, column: 0)
            }
        case 0x73: // s — save cursor
            saveCursorState()
        case 0x75: // u — restore cursor
            restoreCursorState()
        case 0x67: // g — TBC
            if sequence.parameter(0, default: 0) == 3 {
                clearAllTabStops()
            } else {
                removeTabStop(at: activeScreen.cursor.column)
            }
        default:
            break
        }
    }

    private mutating func deviceStatusReport(_ sequence: CSISequence, emit: (TerminalEvent) -> Void) {
        switch sequence.parameter(0, default: 0) {
        case 5:
            emit(.respond(Data("\u{1B}[0n".utf8)))
        case 6:
            let cursor = activeScreen.cursor
            let row = modes.originMode ? cursor.row - activeScreen.scrollTop + 1 : cursor.row + 1
            emit(.respond(Data("\u{1B}[\(row);\(cursor.column + 1)R".utf8)))
        default:
            break
        }
    }

    private mutating func applyCursorStyle(_ sequence: CSISequence) {
        // DECSCUSR: even numbers are steady, odd numbers blink, 0 restores the default.
        let value = sequence.parameter(0, default: 1)
        let style: TerminalCursor.Style
        switch value {
        case 0, 1, 2: style = .block
        case 3, 4: style = .underline
        case 5, 6: style = .bar
        default: return
        }
        let blinks = value == 0 || value % 2 == 1
        withActiveScreenPublic {
            $0.cursor.style = style
            $0.cursor.blinks = blinks
        }
    }

    /// Answers DECRQM for the private modes this terminal has an opinion about.
    ///
    /// The reply is `CSI ? Ps ; Pv $ y`, where `Pv` is 1 for set, 2 for reset, and 0 for
    /// "no such mode here". Reporting 0 for a mode this terminal does not implement is the
    /// honest answer and the useful one: a program then knows not to use it, rather than
    /// sending sequences into a terminal that will draw them as text.
    private func reportMode(_ mode: Int, emit: (TerminalEvent) -> Void) {
        let value: Int
        switch mode {
        case 1: value = modes.applicationCursorKeys ? 1 : 2
        case 6: value = modes.originMode ? 1 : 2
        case 7: value = modes.autoWrap ? 1 : 2
        case 25: value = modes.cursorVisible ? 1 : 2
        case 1000: value = modes.mouseTracking == .click ? 1 : 2
        case 1002: value = modes.mouseTracking == .buttonEvent ? 1 : 2
        case 1003: value = modes.mouseTracking == .anyEvent ? 1 : 2
        case 1004: value = modes.focusReporting ? 1 : 2
        case 1006: value = modes.sgrMouseEncoding ? 1 : 2
        case 1049, 47, 1047: value = modes.alternateScreen ? 1 : 2
        case 2004: value = modes.bracketedPaste ? 1 : 2
        case 2026: value = modes.synchronisedOutput ? 1 : 2
        default: value = 0
        }
        emit(.respond(Data("\u{1B}[?\(mode);\(value)$y".utf8)))
    }

    mutating func applyPrivateCSI(_ sequence: CSISequence, emit: (TerminalEvent) -> Void) {
        guard sequence.privateMarker == 0x3F else { return } // only `?` is handled

        // DECRQM — `CSI ? Ps $ p`: "do you support this mode, and is it on?" (D-062).
        //
        // Answering matters for the modes that change what a program *sends*: a program
        // that cannot tell whether synchronised output is supported either does without it
        // or uses it blindly, and a terminal that ignores the question is guessed about.
        if sequence.intermediates == [0x24], sequence.final == 0x70 {
            reportMode(sequence.parameter(0, default: 0), emit: emit)
            return
        }
        guard sequence.intermediates.isEmpty else { return }

        let enable: Bool
        switch sequence.final {
        case 0x68: enable = true // h — SM
        case 0x6C: enable = false // l — RM
        default: return
        }

        var modesChanged = false
        for parameter in sequence.parameters {
            guard let mode = parameter else { continue }
            switch mode {
            case 1:
                modes.applicationCursorKeys = enable
                modesChanged = true
            case 6:
                modes.originMode = enable
                withActiveScreenPublic { $0.moveCursor(row: enable ? $0.scrollTop : 0, column: 0) }
                modesChanged = true
            case 7:
                modes.autoWrap = enable
                modesChanged = true
            case 5:
                modes.reverseVideo = enable
                modesChanged = true
            case 25:
                modes.cursorVisible = enable
                withActiveScreenPublic { $0.cursor.isVisible = enable }
                modesChanged = true
            case 1000:
                modes.mouseTracking = enable ? .click : .off
                modesChanged = true
            case 1002:
                modes.mouseTracking = enable ? .buttonEvent : .off
                modesChanged = true
            case 1003:
                modes.mouseTracking = enable ? .anyEvent : .off
                modesChanged = true
            case 1006:
                modes.sgrMouseEncoding = enable
                modesChanged = true
            case 1004:
                // Focus reporting: the program wants to know when the terminal has the
                // keyboard, so it can dim a pane or stop animating (D-062).
                modes.focusReporting = enable
                modesChanged = true
            case 2004:
                modes.bracketedPaste = enable
                modesChanged = true
            case 2026:
                // Synchronised output: begin (`h`) means "do not draw what I am about to
                // send until I say end" (`l`). A terminal that ignores it still shows the
                // right thing eventually; one that honours it stops full-screen programs
                // from tearing halfway through a frame on a slow link.
                modes.synchronisedOutput = enable
                modesChanged = true
            case 47, 1047:
                switchAlternateScreen(to: enable, clearOnEnter: true, saveCursor: false)
                emit(.alternateScreenChanged(enable))
                modesChanged = true
            case 1049:
                // 1049 is the combination programs actually use: save the cursor, switch
                // to a cleared alternate screen, and restore both on the way out.
                switchAlternateScreen(to: enable, clearOnEnter: true, saveCursor: true)
                emit(.alternateScreenChanged(enable))
                modesChanged = true
            default:
                break
            }
        }
        if modesChanged { emit(.modesChanged(modes)) }
    }
}
