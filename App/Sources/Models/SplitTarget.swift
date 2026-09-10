import Foundation

/// What a person chose to put in a pane (D-074).
///
/// Splitting used to mean "another shell on this same server", which is what ⌘D does in every
/// tiling terminal and is still what ⌘D does here. But a split screen is a *layout*, and the
/// thing on the other side of the divider is very often something else entirely: a different
/// server, a server that has not been added yet, or a machine's screen over VNC. This is the
/// vocabulary for saying which.
enum SplitTarget: Identifiable, Hashable {
    /// A shell on a connection that is already saved.
    case newSession(Host.ID)
    /// A tmux session on a saved connection that asked for one.
    case newTmuxSession(Host.ID)
    /// A file browser on a saved connection.
    case newFileBrowser(Host.ID)
    /// A saved screen, over VNC.
    case newScreen(ScreenConnection.ID)
    /// Something already open: show it here rather than starting a second one.
    case openSession(UUID)
    case openScreen(UUID)
    case openTmuxSession(UUID)
    case openFileBrowser(UUID)
    /// A server that is not saved yet. The connection editor opens, and what it saves is
    /// what goes in the pane.
    case addConnection
    /// The same for a screen.
    case addScreen

    var id: String {
        switch self {
        case let .newSession(id): "new-session-\(id)"
        case let .newTmuxSession(id): "new-tmux-\(id)"
        case let .newFileBrowser(id): "new-files-\(id)"
        case let .newScreen(id): "new-screen-\(id)"
        case let .openSession(id): "open-session-\(id)"
        case let .openScreen(id): "open-screen-\(id)"
        case let .openTmuxSession(id): "open-tmux-\(id)"
        case let .openFileBrowser(id): "open-files-\(id)"
        case .addConnection: "add-connection"
        case .addScreen: "add-screen"
        }
    }
}

/// A split waiting for its content to be chosen (D-074).
///
/// Carried on the scene rather than in a view's `@State` because the request can come from a
/// keyboard shortcut, from a pane's own menu, or from a pane whose session ended — three
/// places that must all raise the same picker.
struct PendingSplit: Identifiable, Hashable {
    enum Placement: Hashable {
        /// Divide the focused pane, and put the choice in the new half.
        case split(PaneLayout.Axis)
        /// Put the choice in this pane, replacing what is there. Used by a pane whose
        /// session has ended, where splitting would leave the dead one on screen.
        case replace(UUID)
    }

    let id = UUID()
    var placement: Placement

    var axis: PaneLayout.Axis? {
        if case let .split(axis) = placement { return axis }
        return nil
    }
}
