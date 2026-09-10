import Foundation

/// Turns a chosen ``SplitTarget`` into something a pane can hold, opening whatever it needs on
/// the way (D-074).
///
/// Separate from the view that presents the picker so that it can be driven by a test: a
/// `ViewModifier`'s private methods cannot be, and the interesting behaviour is here — which
/// kind of session a connection gets, that a tmux connection attaches rather than opening a
/// plain shell, and that a screen resolves the SSH connection it travels through.
@MainActor
struct SplitTargetResolver {
    let container: AppContainer

    func paneContent(for target: SplitTarget) -> PaneLayout.Content? {
        switch target {
        case let .newSession(hostID):
            guard let host = host(hostID) else { return nil }
            let session = container.sessionManager.open(host)
            container.hostStore.markConnected(host)
            return .terminal(session.id)
        case let .newTmuxSession(hostID):
            guard let host = host(hostID), let session = container.tmux.open(host) else { return nil }
            container.hostStore.markConnected(host)
            return .tmux(session.id)
        case let .newFileBrowser(hostID):
            guard let host = host(hostID) else { return nil }
            let session = container.sessionManager.openFiles(host)
            container.hostStore.markConnected(host)
            return .files(session.id)
        case let .newScreen(screenID):
            guard let screen = container.screenStore.screens.first(where: { $0.id == screenID }) else { return nil }
            let sshHost = screen.route.sshHostID.flatMap(host)
            let session = container.screens.open(screen, through: sshHost)
            container.screenStore.markConnected(screen)
            return .screen(session.id)
        case let .openSession(id): return .terminal(id)
        case let .openScreen(id): return .screen(id)
        case let .openTmuxSession(id): return .tmux(id)
        case let .openFileBrowser(id): return .files(id)
        case .addConnection, .addScreen: return nil
        }
    }

    private func host(_ id: Host.ID) -> Host? {
        container.hostStore.hosts.first { $0.id == id }
    }
}
