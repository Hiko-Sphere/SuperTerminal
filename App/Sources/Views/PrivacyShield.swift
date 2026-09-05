import SwiftUI

/// Full-window cover shown while the scene is not active, so the App Switcher
/// snapshot contains the logo rather than a terminal.
struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            VStack(spacing: DesignTokens.Spacing.md) {
                Image("SuperTerminalLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text("SuperTerminal")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Color.label)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
