import SwiftUI

/// The on-screen key row.
///
/// A phone keyboard has no Escape, no Tab, no Control and no arrows — and without them a
/// terminal is unusable for anything beyond `ls`. This row is therefore core
/// functionality, not a convenience.
struct AccessoryKeyRow: View {
    @Environment(AppContainer.self) private var container
    let session: TerminalSession
    let theme: TerminalTheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                latchButton

                ForEach(AccessoryKey.allCases) { key in
                    keyButton(key)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
        .stBarBackground()
        .overlay(alignment: .top) {
            Divider()
        }
    }

    /// Control latches rather than requiring a chord: holding a modifier while tapping
    /// another key is awkward on a touchscreen, so tapping ctrl then `c` sends ^C.
    private var latchButton: some View {
        Button {
            session.controlLatched.toggle()
            container.haptics.play(.modifierArmed)
        } label: {
            Text("ctrl")
                .font(DesignTokens.Typography.monoCaption)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                        .fill(session.controlLatched ? theme.cursor.swiftUIColor.opacity(0.3) : Color(uiColor: .tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
        // A pointer shows which key it is over, as every other control on iPad does.
        .hoverEffect(.highlight)
        .accessibilityLabel("Control")
        .accessibilityValue(session.controlLatched ? "On" : "Off")
        .accessibilityHint("Latches Control for the next key you press")
    }

    private func keyButton(_ key: AccessoryKey) -> some View {
        Button {
            Task { await sendKey(key) }
        } label: {
            Text(key.label)
                .font(DesignTokens.Typography.monoCaption)
                .frame(minWidth: 34)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                        .fill(Color(uiColor: .tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
        // A pointer shows which key it is over, as every other control on iPad does.
        .hoverEffect(.highlight)
        .accessibilityLabel(key.accessibilityLabel)
    }

    private func sendKey(_ key: AccessoryKey) async {
        let bytes: Data
        switch key {
        case .escape: bytes = Data([0x1B])
        case .tab: bytes = Data([0x09])
        case .up: bytes = cursor("A")
        case .down: bytes = cursor("B")
        case .left: bytes = cursor("D")
        case .right: bytes = cursor("C")
        case .home: bytes = cursor("H")
        case .end: bytes = cursor("F")
        case .pageUp: bytes = Data("\u{1B}[5~".utf8)
        case .pageDown: bytes = Data("\u{1B}[6~".utf8)
        }
        await session.send(bytes)
        session.controlLatched = false
    }

    private func cursor(_ letter: String) -> Data {
        Data((session.modes.applicationCursorKeys ? "\u{1B}O\(letter)" : "\u{1B}[\(letter)").utf8)
    }
}
