import Foundation

extension TerminalEmulator {
    /// Applies Select Graphic Rendition.
    ///
    /// Two spellings of direct colour are in the wild: the semicolon form
    /// (`38;2;r;g;b`, which xterm popularised) and the colon form (`38:2::r:g:b`, which
    /// ITU T.416 actually specifies). Programs emit both, so both are accepted —
    /// handling only one is a common source of "colours look wrong in this one tool".
    mutating func applySGR(_ sequence: CSISequence) {
        var attributes = activeScreen.attributes
        if sequence.parameters.isEmpty {
            attributes = .normal
            attributes.hyperlinkID = currentHyperlink
            withActiveScreenPublic { $0.attributes = attributes }
            return
        }

        var index = 0
        while index < sequence.parameters.count {
            let code = sequence.parameters[index] ?? 0
            let subParameters = index < sequence.subParameters.count ? sequence.subParameters[index] : []

            switch code {
            case 0:
                attributes = .normal
            case 1: attributes.bold = true
            case 2: attributes.dim = true
            case 3: attributes.italic = true
            case 4:
                // `4:0` turns underline off, `4:2` is a double underline.
                if let style = subParameters.first ?? nil {
                    attributes.underline = style != 0
                    attributes.doubleUnderline = style == 2
                } else {
                    attributes.underline = true
                    attributes.doubleUnderline = false
                }
            case 5, 6: attributes.blink = true
            case 7: attributes.inverse = true
            case 8: attributes.invisible = true
            case 9: attributes.strikethrough = true
            case 21:
                attributes.doubleUnderline = true
                attributes.underline = true
            case 22:
                attributes.bold = false
                attributes.dim = false
            case 23: attributes.italic = false
            case 24:
                attributes.underline = false
                attributes.doubleUnderline = false
            case 25: attributes.blink = false
            case 27: attributes.inverse = false
            case 28: attributes.invisible = false
            case 29: attributes.strikethrough = false
            case 30 ... 37: attributes.foreground = .indexed(UInt8(code - 30))
            case 38:
                if let (colour, consumed) = Self.extendedColour(
                    parameters: sequence.parameters,
                    subParameters: subParameters,
                    at: index
                ) {
                    attributes.foreground = colour
                    index += consumed
                }
            case 39: attributes.foreground = .default
            case 40 ... 47: attributes.background = .indexed(UInt8(code - 40))
            case 48:
                if let (colour, consumed) = Self.extendedColour(
                    parameters: sequence.parameters,
                    subParameters: subParameters,
                    at: index
                ) {
                    attributes.background = colour
                    index += consumed
                }
            case 49: attributes.background = .default
            case 90 ... 97: attributes.foreground = .indexed(UInt8(code - 90 + 8))
            case 100 ... 107: attributes.background = .indexed(UInt8(code - 100 + 8))
            default:
                break
            }
            index += 1
        }

        attributes.hyperlinkID = currentHyperlink
        withActiveScreenPublic { $0.attributes = attributes }
    }

    /// Reads a 256-colour or direct-colour argument, in either spelling.
    ///
    /// Returns the colour and how many *additional* parameters it consumed, so the
    /// caller can skip them.
    static func extendedColour(
        parameters: [Int?],
        subParameters: [Int?],
        at index: Int
    ) -> (TerminalColor, Int)? {
        // Colon form: everything travels in the sub-parameters of `38` / `48`.
        if !subParameters.isEmpty {
            switch subParameters.first ?? nil {
            case 5:
                guard subParameters.count >= 2, let value = subParameters[1] else { return nil }
                return (.indexed(UInt8(clamping: value)), 0)
            case 2:
                // T.416 puts an optional colour-space id first, so both `2:r:g:b` and
                // `2::r:g:b` occur.
                let components = subParameters.dropFirst().map { $0 ?? 0 }
                let values = components.count >= 4 ? Array(components.suffix(3)) : Array(components)
                guard values.count >= 3 else { return nil }
                return (
                    .rgb(
                        red: UInt8(clamping: values[0]),
                        green: UInt8(clamping: values[1]),
                        blue: UInt8(clamping: values[2])
                    ),
                    0
                )
            default:
                return nil
            }
        }

        // Semicolon form: the arguments are the following top-level parameters.
        guard index + 1 < parameters.count, let kind = parameters[index + 1] else { return nil }
        switch kind {
        case 5:
            guard index + 2 < parameters.count, let value = parameters[index + 2] else { return nil }
            return (.indexed(UInt8(clamping: value)), 2)
        case 2:
            guard index + 4 < parameters.count else { return nil }
            let red = parameters[index + 2] ?? 0
            let green = parameters[index + 3] ?? 0
            let blue = parameters[index + 4] ?? 0
            return (
                .rgb(
                    red: UInt8(clamping: red),
                    green: UInt8(clamping: green),
                    blue: UInt8(clamping: blue)
                ),
                4
            )
        default:
            return nil
        }
    }
}
