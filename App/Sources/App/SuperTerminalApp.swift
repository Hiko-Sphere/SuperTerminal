import SwiftUI

@main
struct SuperTerminalApp: App {
    /// Built once and handed down explicitly rather than reached for through a global.
    ///
    /// A terminal app holds live network connections and private keys; a shared mutable
    /// singleton would make it impossible to say, in a review, which code can reach the
    /// Keychain or open a socket. Passing the container makes that surface visible.
    @State private var container = AppContainer.live()

    var body: some Scene {
        // Taking a session id means "Open in New Window" can hand the new window
        // something to show. Opened from the app icon the value is nil, which is the
        // ordinary launch.
        WindowGroup(for: TerminalSession.ID.self) { $sessionID in
            RootView(initialSessionID: sessionID)
                .environment(container)
                .tint(DesignTokens.Color.accent)
        }
        // Multiple windows are how iPad multitasking works: Split View, Stage Manager
        // and a second window of the same app all need their own scene.
        .commands { SuperTerminalCommands(container: container) }
    }
}
