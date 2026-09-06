import CloudKit
import SwiftUI
import UIKit

/// Registers for the push notifications iCloud sync needs, and nothing else (D-036).
///
/// `CKSyncEngine` keeps a database subscription so a change made on another device is
/// noticed rather than waited for, and the server refuses a container request from an app
/// that cannot receive one. No notification is ever shown: these are silent, and the only
/// thing that reads them is the sync engine.
final class PushRegistrar: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }
}

@main
struct SuperTerminalApp: App {
    @UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushRegistrar

    /// Built once and handed down explicitly rather than reached for through a global.
    ///
    /// A terminal app holds live network connections and private keys; a shared mutable
    /// singleton would make it impossible to say, in a review, which code can reach the
    /// Keychain or open a socket. Passing the container makes that surface visible.
    @State private var container: AppContainer

    init() {
        let container = AppContainer.live()
        _container = State(initialValue: container)
        // Siri and Shortcuts reach the live container through this handle (D-021).
        IntentContainer.current = IntentContainer(container)
    }

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
