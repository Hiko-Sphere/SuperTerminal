import SwiftUI

/// What the app shows while it is locked (D-023): the app's own passcode, and Face ID or
/// Touch ID in front of it when the user allows. It covers everything, in a window of its
/// own, and gives nothing away about what is behind it.
struct LockScreenView: View {
    let lock: AppLock
    @State private var passcode = ""
    @State private var shake = 0
    @State private var message: String?
    @State private var now = Date()
    @FocusState private var passcodeFocused: Bool

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            DesignTokens.Color.surface.opacity(0.85).ignoresSafeArea()
            VStack(spacing: DesignTokens.Spacing.xl) {
                Spacer(minLength: 0)
                Image("SuperTerminalLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .stCardShadow(DesignTokens.Elevation.sheet)
                Text("SuperTerminal is locked")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Color.label)
                    // The screen's identifier lives on one element: put on the root stack it
                    // is handed down to every child and overwrites the field's own.
                    .accessibilityIdentifier("lock-screen")

                VStack(spacing: DesignTokens.Spacing.md) {
                    SecureField("Passcode", text: $passcode)
                        // On the field itself: past the shake effect the identifier lands on
                        // a wrapper, and a test looking for a secure field finds nothing.
                        .accessibilityIdentifier("lock-passcode")
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .focused($passcodeFocused)
                        .padding(DesignTokens.Spacing.md)
                        .background(DesignTokens.Color.surface, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
                        .frame(maxWidth: 320)
                        .modifier(Shake(animatableData: CGFloat(shake)))
                        .disabled(retrySeconds != nil)

                    Button {
                        submit()
                    } label: {
                        Text("Unlock")
                            .frame(maxWidth: 320)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(passcode.isEmpty || retrySeconds != nil)
                    .accessibilityIdentifier("lock-unlock")

                    if lock.usesBiometrics {
                        Button {
                            Task { await lock.unlockWithBiometrics() }
                        } label: {
                            Label(String(localized: "Unlock with \(lock.biometryKind.title)"), systemImage: lock.biometryKind.systemImage)
                        }
                        .buttonStyle(.bordered)
                        .disabled(lock.isAuthenticating)
                        .accessibilityIdentifier("lock-biometrics")
                    }

                    if let retrySeconds {
                        Text("Too many attempts. Try again in \(retrySeconds) s.")
                            .font(DesignTokens.Typography.callout)
                            .foregroundStyle(DesignTokens.Color.danger)
                            .accessibilityIdentifier("lock-error")
                    } else if let message {
                        Text(message)
                            .font(DesignTokens.Typography.callout)
                            .foregroundStyle(DesignTokens.Color.danger)
                            .accessibilityIdentifier("lock-error")
                    }
                }
                Spacer(minLength: 0)
                Text("Your connections, keys and sessions stay on this device until it is unlocked.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignTokens.Spacing.xl)
                    .padding(.bottom, DesignTokens.Spacing.lg)
            }
            .padding(DesignTokens.Spacing.lg)
        }
        .onReceive(ticker) { now = $0 }
        .task {
            // Offered once per lock; a cancelled prompt does not come straight back.
            if lock.takeAutomaticBiometricsOffer() {
                await lock.unlockWithBiometrics()
            }
            if lock.isLocked { passcodeFocused = true }
        }
    }

    private var retrySeconds: Int? {
        _ = now
        return lock.secondsUntilRetry
    }

    private func submit() {
        guard !passcode.isEmpty else { return }
        if lock.unlock(passcode: passcode) {
            passcode = ""
            message = nil
        } else {
            passcode = ""
            withAnimation(DesignTokens.Motion.standard) { shake += 1 }
            message = lock.secondsUntilRetry == nil ? String(localized: "That passcode is not right.") : nil
        }
    }
}

/// The small sideways shake every passcode field on the platform makes for a wrong entry.
private struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let fraction = animatableData - animatableData.rounded(.down)
        let offset = sin(fraction * .pi * 3) * 8 * (1 - fraction)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}
