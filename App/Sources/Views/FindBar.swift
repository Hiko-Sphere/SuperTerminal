import SwiftUI

/// Search over the terminal's scrollback.
///
/// A terminal's history is where the answer usually is — the error scrolled past three
/// screens ago — so search operates over the whole buffer, not just what is on screen,
/// and jumping to a match scrolls the view to it.
struct FindBar: View {
    @Binding var query: String
    @Binding var caseSensitive: Bool
    let matchCount: Int
    let focusedIndex: Int?
    let onSubmit: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DesignTokens.Color.labelSecondary)

            TextField("Find in scrollback", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isFieldFocused)
                .onSubmit(onSubmit)
                .onChange(of: query) { _, _ in onSubmit() }

            if !query.isEmpty {
                Text(matchLabel)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .monospacedDigit()
            }

            Button {
                caseSensitive.toggle()
                onSubmit()
            } label: {
                Image(systemName: "textformat")
                    .foregroundStyle(caseSensitive ? DesignTokens.Color.accent : DesignTokens.Color.labelSecondary)
            }
            .accessibilityLabel("Match case")
            .accessibilityValue(caseSensitive ? "On" : "Off")

            Button(action: onPrevious) { Image(systemName: "chevron.up") }
                .disabled(matchCount == 0)
                .accessibilityLabel("Previous match")
            Button(action: onNext) { Image(systemName: "chevron.down") }
                .disabled(matchCount == 0)
                .accessibilityLabel("Next match")
            Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                .foregroundStyle(DesignTokens.Color.labelTertiary)
                .accessibilityLabel("Close search")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { isFieldFocused = true }
    }

    private var matchLabel: String {
        guard matchCount > 0 else { return "No matches" }
        guard let focusedIndex else { return "\(matchCount)" }
        return "\(focusedIndex + 1) of \(matchCount)"
    }
}
