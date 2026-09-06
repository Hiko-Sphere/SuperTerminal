import Foundation
import Observation
import SwiftUI

/// What one window is showing.
///
/// Sessions are shared — they are live connections and belong to the app — but *which*
/// session a window displays belongs to the window. Keeping the selection here rather
/// than in ``SessionManager`` is what makes a second window on iPad worth opening:
/// otherwise choosing a session in one window silently changes what the other shows,
/// and two windows are just one window drawn twice.
@Observable
@MainActor
final class SceneState {
    /// Identifies this window to ``SessionManager`` when claiming a session to display.
    let id = UUID()
    var selectedSessionID: TerminalSession.ID?
    /// The remote screen this window shows (D-022) when it shows one instead of a
    /// terminal. Selecting a session clears it, and the other way round.
    var selectedScreenID: VNCSession.ID?

    /// Whether this window is showing the new-connection sheet.
    ///
    /// Per window, because ⌘N used to be a broadcast notification: with two windows open
    /// it opened the sheet in both, including the one the user was not looking at.
    var isCreatingConnection = false
    /// Whether this window is showing the new-screen sheet (D-027).
    var isCreatingScreen = false

    /// Whether the command palette is up in this window.
    var isShowingPalette = false
    /// ⌘, from anywhere in the scene; the host list owns the sheet.
    var isShowingSettings = false
    /// The assistant sheet over the displayed terminal (D-020).
    var isShowingAssistant = false

    init(selectedSessionID: TerminalSession.ID? = nil) {
        self.selectedSessionID = selectedSessionID
    }
}

/// Lets the app's menu commands act on the window the user is actually in.
///
/// Keyboard shortcuts are app-wide but their effect is not: ⌘W means "close the session
/// in *this* window".
struct SceneStateFocusKey: FocusedValueKey {
    typealias Value = SceneState
}

extension FocusedValues {
    var sceneState: SceneState? {
        get { self[SceneStateFocusKey.self] }
        set { self[SceneStateFocusKey.self] = newValue }
    }
}
