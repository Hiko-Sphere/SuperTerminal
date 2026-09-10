import SwiftUI

/// Raises the picker for a split whose content has not been chosen, and puts what was chosen
/// in the pane (D-074).
///
/// A modifier rather than more lines on `RootView.body`, for the same reason `IncomingLinks`
/// is one: that `body` stops type-checking in a Release build long before it stops compiling
/// in a Debug one, which is an archive that fails after every simulator build passed.
struct ChoosesSplitContent: ViewModifier {
    @Environment(AppContainer.self) private var container
    @Bindable var scene: SceneState
    /// A stack-based layout has to push what it opened; a split view's pane is already there.
    let push: (SessionRoute) -> Void

    /// The editors, when the chosen server is one that does not exist yet. Held separately so
    /// that dismissing the picker and presenting an editor is one continuous movement rather
    /// than two sheets fighting over the same binding.
    @State private var addingConnection: PendingSplit?
    @State private var addingScreen: PendingSplit?

    func body(content: Content) -> some View {
        content
            .sheet(item: $scene.pendingSplit) { pending in
                SplitTargetPicker(placement: pending.placement) { target in
                    choose(target, for: pending)
                }
                .environment(container)
                .environment(scene)
            }
            .sheet(item: $addingConnection) { pending in
                HostEditorView(host: nil) { host in
                    place(.newSession(host.id), for: pending)
                }
                .environment(container)
                .environment(scene)
            }
            .sheet(item: $addingScreen) { pending in
                ScreenEditorView(screen: nil) { screen in
                    place(.newScreen(screen.id), for: pending)
                }
                .environment(container)
                .environment(scene)
            }
    }

    private func choose(_ target: SplitTarget, for pending: PendingSplit) {
        switch target {
        // The picker's sheet is on its way out; presenting the editor on the next runloop
        // turn is what stops the system dropping the second presentation on the floor.
        case .addConnection:
            Task { @MainActor in addingConnection = pending }
        case .addScreen:
            Task { @MainActor in addingScreen = pending }
        default:
            place(target, for: pending)
        }
    }

    private func place(_ target: SplitTarget, for pending: PendingSplit) {
        guard let content = SplitTargetResolver(container: container).paneContent(for: target) else { return }
        withAnimation(DesignTokens.Motion.standard) {
            switch pending.placement {
            case let .split(axis):
                _ = scene.panes.split(content, axis: axis)
            case let .replace(paneID):
                scene.panes.replace(paneID, with: content)
            }
        }
        // On a phone there are no two panes side by side: the route is pushed instead, so
        // choosing still takes you to the thing you chose.
        push(route(for: content))
    }

    private func route(for content: PaneLayout.Content) -> SessionRoute {
        switch content {
        case let .terminal(id): .terminal(id)
        case let .screen(id): .screen(id)
        case let .tmux(id): .tmux(id)
        case let .files(id): .files(id)
        }
    }

}
