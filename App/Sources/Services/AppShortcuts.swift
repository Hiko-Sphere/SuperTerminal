import Observation
import SwiftUI
import UIKit

/// The app-level keyboard shortcuts: one table, exposed twice — as SwiftUI shortcut
/// buttons in the shell, and as `UIKeyCommand`s on the terminal view while it has the
/// keyboard — and performed by one router, so a key can never fire twice.
///
/// Why not SwiftUI `Commands`: UI tests that type real keys showed a hardware ⌘N and ⌘K
/// never reaching them on either device (an iPhone has no menu bar at all), and why not
/// the application delegate: SwiftUI's delegate adaptor wraps it and does not forward
/// `keyCommands`. And why not a hidden `UIView` that makes itself first responder: that
/// was the first design, and it was measured to expose an iPadOS 26 focus-engine
/// assertion with a hardware keyboard attached (D-018) — five aborts in eighteen runs of
/// one settings scroll, none in seventeen without it.
enum AppShortcut: String, CaseIterable, Sendable {
    case newConnection, commandPalette, showSettings
    case nextSession, previousSession
    case session1, session2, session3, session4, session5, session6, session7, session8, session9
    case closeSession
    case increaseTextSize, decreaseTextSize, actualTextSize
    /// The same command as `increaseTextSize`, under the key people actually press. ⌘ and
    /// the key marked + is ⇧⌘= to UIKit, which does not match an `=` command — so the
    /// guide would have had to document ⌘= and hope nobody tried the obvious thing.
    case increaseTextSizeShifted
    case assistant
    /// Split panes (D-055). ⌘D and ⇧⌘D are what every tiling terminal uses, and ⌥⌘→ / ⌥⌘←
    /// move between panes without disturbing the shell's own arrow keys.
    case splitRight, splitDown, closePane, nextPane, previousPane
    /// ⌘/ opens the guide — the Help key on every platform that has one, and reachable
    /// with one hand from the terminal (D-056).
    case help

    var title: String {
        switch self {
        case .newConnection: String(localized: "New Connection…")
        case .commandPalette: String(localized: "Command Palette…")
        case .showSettings: String(localized: "Settings…")
        case .nextSession: String(localized: "Next Session")
        case .previousSession: String(localized: "Previous Session")
        case .splitRight: String(localized: "Split Right")
        case .splitDown: String(localized: "Split Down")
        case .closePane: String(localized: "Close Pane")
        case .nextPane: String(localized: "Next Pane")
        case .previousPane: String(localized: "Previous Pane")
        case .closeSession: String(localized: "Close Session")
        case .increaseTextSize, .increaseTextSizeShifted: String(localized: "Increase Text Size")
        case .decreaseTextSize: String(localized: "Decrease Text Size")
        case .actualTextSize: String(localized: "Actual Size")
        case .assistant: String(localized: "Assistant…")
        case .help: String(localized: "User Guide")
        default: String(localized: "Session \(sessionNumber ?? 0)")
        }
    }

    /// ⌘1…⌘9, the way every browser and terminal numbers its tabs.
    var sessionNumber: Int? {
        guard rawValue.hasPrefix("session"), let n = Int(rawValue.dropFirst("session".count)) else { return nil }
        return n
    }

    var input: String {
        switch self {
        case .newConnection: "n"
        case .commandPalette: "k"
        case .showSettings: ","
        case .nextSession: "]"
        case .previousSession: "["
        case .closeSession: "w"
        case .increaseTextSize: "="
        case .increaseTextSizeShifted: "+"
        case .decreaseTextSize: "-"
        case .actualTextSize: "0"
        case .assistant: "a"
        case .help: "/"
        case .splitRight: "d"
        case .splitDown: "d"
        case .closePane: "w"
        case .nextPane: "]"
        case .previousPane: "["
        default: "\(sessionNumber ?? 0)"
        }
    }

    var modifiers: UIKeyModifierFlags {
        switch self {
        case .nextSession, .previousSession, .assistant, .splitDown, .increaseTextSizeShifted: [.command, .shift]
        // Option for the pane commands, so each keeps the letter it shares with its
        // session-level twin: ⌘W still closes the session, ⌥⌘W closes just this pane.
        case .closePane, .nextPane, .previousPane: [.command, .alternate]
        default: .command
        }
    }

    /// The same key in SwiftUI's spelling, for the shell's own shortcut buttons.
    var keyEquivalent: KeyEquivalent { KeyEquivalent(input.first ?? " ") }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = .command
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.alternate) { result.insert(.option) }
        return result
    }

    /// Key commands for the terminal view to return from `keyCommands`; `action` must be
    /// a selector taking the `UIKeyCommand`, which carries the shortcut in `propertyList`.
    static func keyCommands(action: Selector) -> [UIKeyCommand] {
        allCases.map { shortcut in
            let command = UIKeyCommand(title: shortcut.title, action: action, input: shortcut.input,
                                       modifierFlags: shortcut.modifiers, propertyList: shortcut.rawValue)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    init?(command: UICommand) {
        guard let raw = command.propertyList as? String, let shortcut = AppShortcut(rawValue: raw) else { return nil }
        self = shortcut
    }
}

/// Performs the shortcuts against the active scene. Held by the container so every
/// responder routes to the same instance.
@Observable
@MainActor
final class AppShortcutRouter {
    private let sessionManager: SessionManager
    private let settings: AppSettings
    /// The scene most recently active — set after the container exists.
    var sceneProvider: () -> SceneState? = { nil }
    #if DEBUG
    /// Diagnostics for the UI tests: how many shortcuts were matched and performed, and the
    /// last one seen with its availability. A hardware key that was dropped by the simulator
    /// before the app leaves these unchanged, which is how the tests tell that apart from a
    /// key the app received and ignored.
    var debugShortcutsPerformed = 0
    var debugLast = "-"
    #endif

    init(sessionManager: SessionManager, settings: AppSettings) {
        self.sessionManager = sessionManager
        self.settings = settings
    }

    private var scene: SceneState? { sceneProvider() }
    private var displayedSession: TerminalSession? { sessionManager.session(withID: scene?.selectedSessionID) }

    /// Whether the shortcut can do anything right now. A shortcut that is listed but does
    /// nothing is worse than one that is not listed: the user concludes the app is broken
    /// rather than that the command does not apply.
    func isAvailable(_ shortcut: AppShortcut) -> Bool {
        switch shortcut {
        case .nextSession, .previousSession: sessionManager.sessions.count >= 2
        case .closeSession, .assistant: displayedSession != nil
        case .newConnection, .commandPalette, .showSettings, .actualTextSize, .help: scene != nil
        // Splitting needs something to split, and the pane commands need more than one
        // pane — a "Close Pane" that closes the only pane is just "Close Session" wearing
        // the wrong name.
        case .splitRight, .splitDown: displayedSession != nil || scene?.panes.paneCount ?? 0 > 0
        case .closePane, .nextPane, .previousPane: (scene?.panes.paneCount ?? 0) >= 2
        case .increaseTextSize, .increaseTextSizeShifted: settings.fontSize < AppSettings.fontSizeRange.upperBound
        case .decreaseTextSize: settings.fontSize > AppSettings.fontSizeRange.lowerBound
        default: shortcut.sessionNumber.map { sessionManager.session(atOneBasedIndex: $0) != nil } ?? false
        }
    }

    func perform(_ shortcut: AppShortcut) {
        #if DEBUG
        debugShortcutsPerformed += 1
        debugLast = "\(shortcut.rawValue):\(isAvailable(shortcut) ? "available" : "unavailable"):\(scene == nil ? "noScene" : "scene")"
        #endif
        guard isAvailable(shortcut) else { return }
        switch shortcut {
        case .newConnection: scene?.isCreatingConnection = true
        case .commandPalette: scene?.isShowingPalette = true
        case .showSettings: scene?.isShowingSettings = true
        case .nextSession: cycleSession(by: 1)
        case .previousSession: cycleSession(by: -1)
        case .closeSession: if let session = displayedSession { sessionManager.close(session) }
        case .increaseTextSize, .increaseTextSizeShifted: adjustFontSize(by: 1)
        case .decreaseTextSize: adjustFontSize(by: -1)
        case .actualTextSize: settings.fontSize = AppSettings.defaultFontSize
        case .assistant: scene?.isShowingAssistant = true
        case .help: scene?.isShowingHelp = true
        case .splitRight: splitFocusedPane(axis: .horizontal)
        case .splitDown: splitFocusedPane(axis: .vertical)
        case .closePane:
            if let scene, let focused = scene.panes.focused { scene.panes.close(focused) }
        case .nextPane: scene?.panes.focusNext()
        case .previousPane: scene?.panes.focusNext(reverse: true)
        default:
            if let number = shortcut.sessionNumber, let scene, let session = sessionManager.session(atOneBasedIndex: number) {
                scene.selectedSessionID = session.id
            }
        }
    }

    /// Whole points, clamped to what Settings allows; the terminal re-measures its grid.
    private func adjustFontSize(by delta: Double) {
        let range = AppSettings.fontSizeRange
        settings.fontSize = min(max(settings.fontSize + delta, range.lowerBound), range.upperBound)
    }

    /// Splits the focused pane, putting a *new session to the same server* in the new half.
    ///
    /// Splitting means "another one of these", which is what every tiling terminal does and
    /// what someone reaching for ⌘D wants — a second shell on the machine they are already
    /// looking at, not an empty pane asking them to pick a server again. Connection reuse
    /// (D-054) makes that nearly free: the second shell is another channel on the transport
    /// the first one already has.
    private func splitFocusedPane(axis: PaneLayout.Axis) {
        guard let scene else { return }
        guard case let .terminal(id)? = scene.panes.focusedContent ?? displayedSession.map({ .terminal($0.id) }),
              let existing = sessionManager.session(withID: id)
        else { return }
        let session = sessionManager.open(existing.host)
        scene.panes.split(.terminal(session.id), axis: axis)
    }

    private func cycleSession(by delta: Int) {
        guard let scene, let session = sessionManager.session(after: scene.selectedSessionID, delta: delta) else { return }
        scene.selectedSessionID = session.id
    }
}
