import SwiftUI

/// The tour (D-033).
///
/// Shown once, after the consent screen, on a device that has not seen it — and never
/// again unasked. Skipping and finishing are the same outcome: the tour is not a gate,
/// and a person who wants to get on with it should not be made to page through six
/// screens to prove it. Settings → Help reopens it, which is why skipping can be
/// offered without stranding anyone.
struct TutorialView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Called when the tour is finished or skipped — the caller decides what that means.
    let onFinish: () -> Void

    @State private var index = 0
    /// Drives the illustrations' entrance. Keyed by page, so paging back and forth
    /// replays the assembly rather than showing a picture that has already landed.
    @State private var phase: Double = 0

    private var pages: [TutorialPage] { TutorialPage.all }
    private var isLast: Bool { index == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $index) {
                ForEach(pages) { page in
                    pageView(page).tag(page.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            footer
        }
        .background(DesignTokens.Color.surfaceGrouped)
        // Deliberately no identifier on this container: in SwiftUI an identifier applied
        // to a view that contains controls is inherited by all of them, so every button
        // inside came back as "tutorial" and none could be found by its own name. The
        // tour's presence is asserted through the controls themselves.
        .onAppear { animateIn() }
        .onChange(of: index) { _, _ in
            container.haptics.play(.selectionChanged)
            animateIn()
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Spacer()
            Button {
                finish(skipped: true)
            } label: {
                Text("Skip")
                    .font(DesignTokens.Typography.callout)
            }
            .accessibilityIdentifier("tutorial-skip")
            .accessibilityHint(Text("Closes the tour. You can reopen it from Settings."))
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.top, DesignTokens.Spacing.md)
    }

    private func pageView(_ page: TutorialPage) -> some View {
        GeometryReader { proxy in
            ScrollView {
                pageContent(page)
                    .frame(minHeight: proxy.size.height, alignment: .center)
            }
        }
    }

    private func pageContent(_ page: TutorialPage) -> some View {
        VStack(spacing: DesignTokens.Spacing.xl) {
                TutorialIllustration(kind: page.illustration, phase: phase)
                    .frame(maxWidth: .infinity)

                VStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: page.symbol)
                        .font(.system(size: 22))
                        .foregroundStyle(DesignTokens.Color.accent)
                    Text(page.title)
                        .font(DesignTokens.Typography.title)
                        .multilineTextAlignment(.center)
                    Text(page.body)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // One element rather than three, so VoiceOver reads the page as a
                // sentence instead of making the reader swipe through its parts.
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(page.title). \(page.body)"))
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.vertical, DesignTokens.Spacing.xl)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(pages) { page in
                    Capsule()
                        .fill(page.id == index ? DesignTokens.Color.accent : DesignTokens.Color.separator)
                        .frame(width: page.id == index ? 18 : 6, height: 6)
                }
            }
            .animation(reduceMotion ? nil : DesignTokens.Motion.emphasised, value: index)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Step \(index + 1) of \(pages.count)"))

            HStack(spacing: DesignTokens.Spacing.md) {
                if index > 0 {
                    Button {
                        withAnimation(reduceMotion ? nil : DesignTokens.Motion.standard) { index -= 1 }
                    } label: {
                        Text("Back")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DesignTokens.Spacing.md)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("tutorial-back")
                }
                Button {
                    if isLast {
                        finish(skipped: false)
                    } else {
                        withAnimation(reduceMotion ? nil : DesignTokens.Motion.standard) { index += 1 }
                    }
                } label: {
                    Text(isLast ? "Get started" : "Continue")
                        .font(DesignTokens.Typography.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.Spacing.md)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(isLast ? "tutorial-done" : "tutorial-next")
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.bottom, DesignTokens.Spacing.xl)
        .padding(.top, DesignTokens.Spacing.lg)
    }

    // MARK: - Behaviour

    private func animateIn() {
        guard !reduceMotion else { phase = 1; return }
        phase = 0
        withAnimation(.easeOut(duration: 0.75)) { phase = 1 }
    }

    private func finish(skipped: Bool) {
        container.haptics.play(.textInserted)
        onFinish()
    }
}
