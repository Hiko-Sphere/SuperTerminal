import SwiftUI

/// Defers building a navigation destination until it is actually shown.
///
/// A closure-based `NavigationLink` inside a `List` builds its destination as soon as the row
/// appears — which is why `navigationDestination(for:)` exists. So opening Settings built the
/// whole theme workshop, off screen, with nobody looking at it; and on iPadOS that was not merely
/// wasteful. The workshop had a section whose only content was a `ContentUnavailableView`, which
/// is not focusable, so the focus engine built a container with no items and asserted the moment
/// the Settings form was scrolled — a reproducible crash on an iPad, reached without ever opening
/// the screen that contained the mistake (D-080).
///
/// The section was wrong and is fixed. This is the other half: a destination that is not on
/// screen should not be built, so the next screen with a quirk in it cannot reach out of the row
/// that merely links to it.
struct LazyDestination<Content: View>: View {
    private let build: () -> Content

    init(@ViewBuilder _ build: @escaping () -> Content) {
        self.build = build
    }

    var body: some View {
        build()
    }
}
