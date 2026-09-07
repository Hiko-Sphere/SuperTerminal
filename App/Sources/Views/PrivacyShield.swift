import SwiftUI

/// Full-window cover shown while the scene is not active, so the App Switcher
/// snapshot contains the logo rather than a terminal.
struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            VStack(spacing: DesignTokens.Spacing.md) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text("Apex Terminal")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Color.label)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        // Visual only. The App Switcher snapshot does not depend on this taking input, and
        // a scene that is merely inactive — an unfocused window under Stage Manager, or one
        // moment of a transition — would otherwise swallow the click meant for the terminal.
        .allowsHitTesting(false)
    }
}
