import Observation
import UIKit

/// The app's haptic vocabulary, in one place.
///
/// Haptics are a language, and a language only works if it is consistent: the same tap
/// must mean the same thing everywhere, and things that are not worth interrupting
/// someone for must stay silent. Scattered `UIImpactFeedbackGenerator()` calls drift into
/// meaning nothing, and every one of them allocates a generator that has not been warmed
/// up — which is the difference between a tap that lands with the action and one that
/// arrives a beat late and feels broken.
///
/// Deliberately narrow. There is no feedback for keystrokes or for output arriving: a
/// terminal produces both constantly, and a phone buzzing through a build log is not a
/// feature.
@Observable
@MainActor
final class Haptics {
    /// What happened. Named for the event rather than the sensation, so a call site says
    /// *why* it is asking rather than picking a texture.
    enum Event {
        /// A session reached a shell.
        case connected
        /// A session ended, or was lost.
        case disconnected
        /// Something failed in a way the user has to deal with.
        case failed
        /// A modifier was armed — Control latched, ready for the next character.
        case modifierArmed
        /// The selection moved to a new cell, word or line.
        case selectionChanged
        /// The remote program rang the bell.
        case bell
        /// Text was inserted for the user: a snippet, a paste, a completed action.
        case textInserted
    }

    private let settings: AppSettings
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)

    init(settings: AppSettings) {
        self.settings = settings
    }

    func play(_ event: Event) {
        guard settings.hapticsEnabled else { return }
        switch event {
        case .connected:
            notification.notificationOccurred(.success)
        case .disconnected:
            notification.notificationOccurred(.warning)
        case .failed:
            notification.notificationOccurred(.error)
        case .modifierArmed:
            // Impact rather than selection: arming a modifier changes what the *next*
            // key will do, which is a heavier thing than moving a highlight.
            mediumImpact.impactOccurred()
        case .selectionChanged:
            selection.selectionChanged()
        case .bell:
            lightImpact.impactOccurred()
        case .textInserted:
            lightImpact.impactOccurred()
        }
    }

    /// Warms up the engine for a haptic that is about to happen.
    ///
    /// The Taptic Engine takes time to spin up, and a haptic played cold arrives late
    /// enough to feel disconnected from what caused it. Called when a gesture begins,
    /// not when it ends.
    func prepare(for event: Event) {
        guard settings.hapticsEnabled else { return }
        switch event {
        case .connected, .disconnected, .failed: notification.prepare()
        case .modifierArmed: mediumImpact.prepare()
        case .selectionChanged: selection.prepare()
        case .bell, .textInserted: lightImpact.prepare()
        }
    }
}
