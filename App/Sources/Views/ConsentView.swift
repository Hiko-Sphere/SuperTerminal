import SwiftUI

/// Shown once, before anything else, and again whenever the documents change.
///
/// It is a summary with the full texts one tap away, and one button. The Terms say what
/// not accepting means — not using the app — so there is no second button pretending
/// otherwise.
struct ConsentView: View {
    @Environment(AppContainer.self) private var container
    let onAccept: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    HStack(spacing: DesignTokens.Spacing.md) {
                        Image("SuperTerminalLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                            Text("Before you start")
                                .font(DesignTokens.Typography.title)
                            Text("Three things worth knowing, and the documents behind them.")
                                .font(DesignTokens.Typography.callout)
                                .foregroundStyle(DesignTokens.Color.labelSecondary)
                        }
                    }

                    point("lock.shield", "Your keys stay on your device.",
                          "Private keys live in Apple's Keychain and are never sent to a server. iCloud sync is off until you turn it on, and even then only keys you choose go to iCloud Keychain.")
                    point("network", "Nothing goes to the developer.",
                          "There is no account, no server, no analytics and no crash reporter. Traffic goes only to the servers you connect to and, for tunnelled hosts, to Cloudflare on your behalf.")
                    point("checkmark.seal", "You verify the first fingerprint.",
                          "The app cannot tell a real server from an impostor on a first connection. Compare the fingerprint it shows with what the server reports. A changed key is always refused until you decide.")

                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        ForEach([LegalDocument.notice, .privacy, .terms]) { document in
                            NavigationLink { LegalView(document: document) } label: {
                                HStack {
                                    Text(document.title)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(DesignTokens.Color.labelTertiary)
                                }
                                .padding(.vertical, DesignTokens.Spacing.sm)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("consent-\(document.rawValue)")
                            Divider()
                        }
                    }

                    Text("By continuing you accept the Terms of Use and confirm you have read the Privacy Policy and the User Notice. You may only connect to systems you are allowed to access.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                }
                .padding(DesignTokens.Spacing.lg)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    container.haptics.play(.textInserted)
                    onAccept()
                } label: {
                    Text("Accept and continue")
                        .font(DesignTokens.Typography.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.md)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .accessibilityIdentifier("consent-accept")
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }

    private func point(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(DesignTokens.Color.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(title).font(DesignTokens.Typography.headline)
                Text(detail).font(DesignTokens.Typography.callout).foregroundStyle(DesignTokens.Color.labelSecondary)
            }
        }
    }
}
