import CoreGraphics
import Foundation
import NIOCore
import NIOTransportServices
import STCloudflare
import Observation
import STCore
import STSSH
import STVNC

/// A remote screen (D-022): one VNC connection, its framebuffer as an image, and the
/// input the user sends to it.
///
/// Reached through the SSH connection the host describes — a `direct-tcpip` channel to
/// the screen-sharing port as the server sees it, the way `ssh -L` works — or straight
/// over TCP when the user chose that. The SSH route is the default because RFB carries
/// the screen in the clear and its password check is a 1990s DES challenge; the editor
/// says so.
@Observable
@MainActor
final class VNCSession: Identifiable {
    enum State: Equatable {
        case idle
        case connecting(step: String)
        /// Waiting for the user: a host key to trust, a password to enter.
        case awaitingUser(prompt: TerminalSession.PendingPrompt)
        case connected
        case disconnected(reason: String?)
        case failed(STError)
    }

    /// Modifier keys the on-screen key row latches for the next key.
    struct Modifiers: OptionSet, Sendable, Hashable {
        let rawValue: Int
        static let shift = Modifiers(rawValue: 1)
        static let control = Modifiers(rawValue: 2)
        static let alt = Modifiers(rawValue: 4)
        /// The Windows or ⌘ key, `Super_L` in X11's vocabulary.
        static let superKey = Modifiers(rawValue: 8)

        var keysyms: [UInt32] {
            var result: [UInt32] = []
            if contains(.shift) { result.append(VNCKeysym.shiftLeft) }
            if contains(.control) { result.append(VNCKeysym.controlLeft) }
            if contains(.alt) { result.append(VNCKeysym.altLeft) }
            if contains(.superKey) { result.append(VNCKeysym.superLeft) }
            return result
        }
    }

    /// RFB pointer buttons, as bits of the mask a pointer event carries.
    enum Button: UInt8 {
        case left = 1, middle = 2, right = 4
        case wheelUp = 8, wheelDown = 16, wheelLeft = 32, wheelRight = 64
    }

    let id = UUID()
    let screen: ScreenConnection
    /// The SSH connection the screen's route names, resolved when it was opened. `nil`
    /// for a direct screen — and `nil` when the route names a connection that no longer
    /// exists, which `connect` reports rather than quietly connecting some other way.
    let sshHost: Host?

    private(set) var state: State = .idle
    /// The framebuffer, redrawn at most once per display frame.
    private(set) var image: CGImage?
    private(set) var desktopName = ""
    private(set) var desktopSize = CGSize.zero
    /// Text the remote put on its clipboard. Offered, never copied silently: the user's
    /// clipboard is theirs, and a remote desktop should not be able to overwrite it.
    private(set) var remoteClipboard: String?
    /// Modifiers latched by the key row, sent around the next key.
    var latchedModifiers: Modifiers = []
    /// Whether ⌘ goes to the remote as Super rather than to the app's own shortcuts.
    var sendsCommandKey = false

    var isConnected: Bool { if case .connected = state { return true }; return false }
    var displayName: String { desktopName.isEmpty ? screen.name : desktopName }

    private var client: VNCClient?
    private var connection: SSHConnection?
    private var eventsTask: Task<Void, Never>?
    private var redrawScheduled = false
    private let connector: HostConnector?
    private let prompts: PromptCoordinator
    private let group: NIOTSEventLoopGroup
    private let vault: CredentialVault
    private let log: STLogger
    private let haptics: Haptics?

    init(
        screen: ScreenConnection,
        sshHost: Host?,
        group: NIOTSEventLoopGroup,
        vault: CredentialVault,
        knownHosts: any KnownHostsStore,
        log: STLogger,
        haptics: Haptics? = nil
    ) {
        self.screen = screen
        self.sshHost = sshHost
        self.group = group
        self.vault = vault
        self.haptics = haptics
        let sessionLog = log.child(subsystem: "screen")
        self.log = sessionLog
        let prompts = PromptCoordinator()
        self.prompts = prompts
        // Built only when there is an SSH connection to make; a direct screen never
        // touches SSH at all.
        connector = sshHost.map {
            HostConnector(host: $0, group: group, vault: vault, knownHosts: knownHosts, log: sessionLog, prompts: prompts)
        }
        Task { [weak self, prompts] in
            await prompts.setPromptHandler { prompt in
                Task { @MainActor in self?.state = .awaitingUser(prompt: prompt) }
            }
        }
    }

    // MARK: - Lifecycle

    func connect() async {
        guard !isConnected else { return }
        state = .connecting(step: String(localized: "Resolving \(screen.address)"))
        do {
            var password = screen.hasPassword ? try vault.loadVNCPassword(screenID: screen.id) : nil
            if case .throughSSH = screen.route {
                guard let connector else {
                    state = .failed(STError(
                        category: .configuration,
                        message: String(localized: "The SSH connection this screen goes through no longer exists."),
                        recoverySuggestion: String(localized: "Edit the screen and choose an SSH connection, or connect to it directly.")
                    ))
                    return
                }
                if connection == nil {
                    connection = try await connector.connect { [weak self] step in
                        self?.state = .connecting(step: step)
                    }
                }
            }
            // The server says whether it wants a password only after the version
            // exchange, and the challenge it sends is single-use — so a server that
            // asks when nothing is stored gets one fresh attempt with what the user types.
            for attempt in 0 ..< 2 {
                do {
                    try await open(password: password)
                    break
                } catch VNCError.passwordRequired where attempt == 0 {
                    password = try await prompts.requestPassword(
                        username: String(localized: "screen sharing"),
                        host: screen.name
                    )
                    state = .connecting(step: String(localized: "Starting screen sharing"))
                }
            }
            state = .connected
            haptics?.play(.connected)
            log.info("screen connected", ["address": Redactor.hostname(screen.address), "direct": "\(screen.route.isDirect)"])
        } catch let error as STError {
            await tearDown()
            state = .failed(error)
            log.error("screen failed", ["category": error.category.rawValue])
        } catch let error as VNCError {
            await tearDown()
            state = .failed(Self.describe(error))
            log.error("screen refused", ["reason": String(describing: error)])
        } catch {
            await tearDown()
            state = .failed(STError(
                category: .internalError,
                message: String(localized: "The screen could not be opened."),
                underlyingDescription: String(describing: error)
            ))
        }
    }

    /// One handshake over a fresh channel.
    private func open(password: String?) async throws {
        let channel: Channel
        switch screen.route {
        case .direct:
            state = .connecting(step: String(localized: "Connecting to the screen"))
            channel = try await DirectTCPTransport(
                endpoint: TransportEndpoint(host: screen.address, port: screen.port),
                log: log
            ).connect(on: group.next())
        case .throughSSH:
            guard let connection else { throw VNCError.protocolError("no SSH connection") }
            state = .connecting(step: String(localized: "Opening a tunnel to the screen"))
            channel = try await connection.openDirectTCPIP(host: screen.address, port: screen.port)
        case .cloudflare:
            // The same carrier the SSH transport rides: an ordinary WebSocket whose binary
            // frames are a raw TCP stream, with the tunnel's own ingress deciding where the
            // VNC server is (D-001, D-029).
            state = .connecting(step: String(localized: "Checking Cloudflare Access"))
            let credential: AccessCredential
            do {
                credential = try await AccessCredentialResolver(
                    hostname: screen.address,
                    port: screen.port,
                    usesServiceToken: screen.usesServiceToken,
                    serviceToken: { [vault, screen] in try vault.loadServiceToken(screenID: screen.id) },
                    vault: vault,
                    log: log
                ).credential { [weak self] step in
                    self?.state = .connecting(step: step)
                }
            } catch let error as AccessError {
                // Every Access failure already describes itself; without this they all
                // arrive as "the screen could not be opened" (D-026).
                throw error.stError
            }
            state = .connecting(step: String(localized: "Opening the tunnel to the screen"))
            channel = try await CloudflareCarrierTransport(
                configuration: .init(
                    host: screen.address,
                    port: screen.port,
                    userAgent: AccessCredentialResolver.userAgent
                ),
                credential: credential,
                log: log
            ).connect(on: group.next())
        }
        state = .connecting(step: String(localized: "Starting screen sharing"))
        let client = try await VNCClient.start(on: channel, options: .init(password: password))
        self.client = client
        consumeEvents(from: client)
    }

    func disconnect() async {
        await tearDown()
        if case .connected = state { state = .disconnected(reason: nil) }
    }

    func retry() {
        Task { await connect() }
    }

    private func tearDown() async {
        eventsTask?.cancel()
        eventsTask = nil
        if let client { await client.close() }
        if let connection { await connection.close() }
        client = nil
        connection = nil
    }

    /// Answers a prompt the connection is waiting on.
    func resolvePrompt(_ decision: PromptCoordinator.Decision) {
        let prompts = prompts
        Task { await prompts.resolve(decision) }
        if case .awaitingUser = state { state = .connecting(step: String(localized: "Continuing")) }
    }

    private func consumeEvents(from client: VNCClient) {
        eventsTask = Task { [weak self] in
            for await event in client.events {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case let .connected(width, height, name):
                    desktopName = name
                    desktopSize = CGSize(width: width, height: height)
                    scheduleRedraw()
                case .framebufferUpdated:
                    scheduleRedraw()
                case let .resized(width, height):
                    desktopSize = CGSize(width: width, height: height)
                    scheduleRedraw()
                case .bell:
                    haptics?.play(.bell)
                case let .serverCutText(text):
                    remoteClipboard = text
                case let .closed(reason):
                    if case .connected = state {
                        state = .disconnected(reason: reason)
                        haptics?.play(.disconnected)
                    }
                }
            }
        }
    }

    /// Coalesces a burst of rectangles into one image per display frame. Decoding is
    /// already done by the time an event arrives; this is only the copy to the screen.
    private func scheduleRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self else { return }
            redrawScheduled = false
            if let client { image = client.framebuffer.makeImage() }
        }
    }

    // MARK: - Input

    /// Moves the pointer, with `buttons` as the mask of buttons currently held.
    func pointer(x: Int, y: Int, buttons: UInt8) {
        client?.sendPointer(buttons: buttons, x: x, y: y)
    }

    func click(x: Int, y: Int, button: Button) {
        client?.sendPointer(buttons: button.rawValue, x: x, y: y)
        client?.sendPointer(buttons: 0, x: x, y: y)
    }

    /// Scroll-wheel steps: positive `vertical` scrolls down, positive `horizontal` right.
    func wheel(x: Int, y: Int, vertical: Int, horizontal: Int) {
        for _ in 0 ..< abs(vertical) { click(x: x, y: y, button: vertical > 0 ? .wheelDown : .wheelUp) }
        for _ in 0 ..< abs(horizontal) { click(x: x, y: y, button: horizontal > 0 ? .wheelRight : .wheelLeft) }
    }

    func key(_ keysym: UInt32, down: Bool) {
        client?.sendKey(keysym: keysym, down: down)
    }

    /// A press and release, wrapped in whatever the key row latched; the latch clears.
    func press(_ keysym: UInt32) {
        let modifiers = latchedModifiers.keysyms
        for modifier in modifiers { key(modifier, down: true) }
        key(keysym, down: true)
        key(keysym, down: false)
        for modifier in modifiers.reversed() { key(modifier, down: false) }
        latchedModifiers = []
    }

    /// A chord such as Ctrl+Alt+Del: modifiers down, the key, modifiers up.
    func chord(_ modifiers: Modifiers, _ keysym: UInt32) {
        let held = modifiers.keysyms
        for modifier in held { key(modifier, down: true) }
        key(keysym, down: true)
        key(keysym, down: false)
        for modifier in held.reversed() { key(modifier, down: false) }
    }

    /// Types text from the on-screen keyboard, one key event pair per character.
    func type(_ text: String) {
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\r": press(VNCKeysym.return)
            case "\t": press(VNCKeysym.tab)
            default: press(VNCKeysym.forCharacter(scalar))
            }
        }
    }

    /// Puts text on the remote clipboard, so it can be pasted there.
    func sendClipboard(_ text: String) {
        client?.sendCutText(text)
    }

    func takeRemoteClipboard() -> String? {
        defer { remoteClipboard = nil }
        return remoteClipboard
    }

    // MARK: - Errors

    private static func describe(_ error: VNCError) -> STError {
        switch error {
        case let .authenticationFailed(reason):
            STError(
                category: .credential,
                message: String(localized: "The screen sharing server refused the password."),
                recoverySuggestion: String(localized: "Check the VNC password in this screen's settings. It is separate from the SSH password."),
                underlyingDescription: reason
            )
        case .passwordRequired:
            STError(
                category: .credential,
                message: String(localized: "This screen needs a VNC password."),
                recoverySuggestion: String(localized: "Edit the screen and enter its VNC password.")
            )
        case let .noAcceptableSecurity(offered):
            STError(
                category: .configuration,
                message: String(localized: "The server offers only screen sharing security types this app does not support."),
                recoverySuggestion: String(localized: "On a Mac, turn on “VNC viewers may control screen with password” in Screen Sharing settings. On other servers, enable VNC password authentication."),
                underlyingDescription: "offered \(offered)"
            )
        case let .unsupportedVersion(version):
            STError(
                category: .configuration,
                message: String(localized: "The server speaks a screen sharing protocol version this app does not support."),
                underlyingDescription: version
            )
        case let .protocolError(detail):
            STError(
                category: .network,
                message: String(localized: "The screen sharing connection ended unexpectedly."),
                recoverySuggestion: String(localized: "Check that the port is a VNC server and try again."),
                underlyingDescription: detail
            )
        }
    }
}
