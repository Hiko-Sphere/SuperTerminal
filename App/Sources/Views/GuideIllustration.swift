import SwiftUI

/// A drawn picture inside a user-guide topic (D-080).
///
/// The same pictures the tour uses, reached from the guide's Markdown by name. Reusing them
/// rather than drawing a second set is the point: they are built from the design tokens of the
/// interface they describe, so there is exactly one place where a picture of the key row can
/// fall out of step with the key row.
///
/// The entrance is the tour's too — each element arriving in order rather than the whole block
/// appearing at once — held back by the length of the navigation push so it plays *on* the
/// topic rather than during the slide onto it. A topic carries one picture, so nothing here
/// needs to know what is on screen.
struct GuideIllustration: View {
    let kind: TutorialPage.Illustration

    @State private var phase: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TutorialIllustration(kind: kind, phase: phase)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .task {
                guard phase == 0 else { return }
                // Reduce Motion means the picture is simply there. Assembling it is
                // decoration: it says nothing the finished picture does not.
                guard !reduceMotion else { phase = 1; return }
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.easeOut(duration: 0.55)) { phase = 1 }
            }
    }
}
