import AuthenticationServices
import Foundation
import STCloudflare
import STCore
import STSSH
import UIKit

/// Bridges decisions that only a person can make — trusting a host key, entering a
/// password — between the connection code, which runs off the main actor, and the UI,
/// which does not.
///
/// It is an actor rather than a lock-guarded class because the whole point is to *wait*:
/// the connection genuinely suspends until the user answers, and a lock held across that
/// suspension would be both unsafe and rejected by the compiler.
actor PromptCoordinator: HostKeyApprovalDelegate {
    enum Decision: Sendable {
        case approve
        case reject
        case password(String)
        case passphrase(String)
        case username(String)
    }

    private var pending: CheckedContinuation<Decision, Never>?
    private var promptHandler: (@Sendable (TerminalSession.PendingPrompt) -> Void)?

    /// Installs the callback that surfaces a prompt in the UI.
    func setPromptHandler(_ handler: @escaping @Sendable (TerminalSession.PendingPrompt) -> Void) {
        promptHandler = handler
    }

    /// Delivers the user's answer to whatever is waiting.
    func resolve(_ decision: Decision) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(returning: decision)
    }

    private func awaitDecision(raising prompt: TerminalSession.PendingPrompt) async -> Decision {
        // A prompt raised while another is outstanding cannot happen in the current
        // flow, but rejecting the old one rather than dropping it means a future change
        // cannot silently strand a suspended connection.
        if let previous = pending {
            pending = nil
            previous.resume(returning: .reject)
        }
        promptHandler?(prompt)
        return await withCheckedContinuation { continuation in
            pending = continuation
        }
    }

    // MARK: - HostKeyApprovalDelegate

    func approveUnknownHost(identity: KnownHostIdentity, key: SSHHostKey) async -> Bool {
        if case .approve = await awaitDecision(raising: .unknownHostKey(identity: identity, key: key)) {
            return true
        }
        return false
    }

    func approveChangedHost(
        identity: KnownHostIdentity,
        expected: SSHHostKey,
        presented: SSHHostKey
    ) async -> Bool {
        let decision = await awaitDecision(
            raising: .changedHostKey(identity: identity, expected: expected, presented: presented)
        )
        if case .approve = decision { return true }
        return false
    }

    // MARK: - Secrets

    func requestPassword(username: String, host: String) async throws -> String {
        let decision = await awaitDecision(raising: .password(username: username, host: host))
        guard case let .password(value) = decision else {
            throw STError(category: .cancelled, message: String(localized: "Password entry was cancelled."))
        }
        return value
    }

    func requestPassphrase(keyName: String) async throws -> String {
        let decision = await awaitDecision(raising: .keyPassphrase(keyName: keyName))
        guard case let .passphrase(value) = decision else {
            throw STError(category: .cancelled, message: String(localized: "Passphrase entry was cancelled."))
        }
        return value
    }

    /// The user name for a connection saved without one (D-024).
    func requestUsername(host: String) async throws -> String {
        let decision = await awaitDecision(raising: .username(host: host))
        guard case let .username(value) = decision, !value.isEmpty else {
            throw STError(category: .cancelled, message: String(localized: "User name entry was cancelled."))
        }
        return value
    }

    /// The server takes a password and nothing stored is left: ask, or `nil` if the
    /// person declines. Called from the SSH event loop through the credential chain.
    func requestPasswordIfWanted(username: String, host: String) async -> String? {
        let decision = await awaitDecision(raising: .password(username: username, host: host))
        guard case let .password(value) = decision else { return nil }
        return value
    }
}

/// Presents the Cloudflare Access login in a system authentication session.
///
/// `ASWebAuthenticationSession` is the only supported way to show an identity provider's
/// page: it runs out of process, so the app never sees the credentials typed into it, and
/// it shares Safari's cookie jar, so an existing SSO session is reused rather than making
/// the user sign in from scratch every time.
///
/// The session's callback is deliberately unused. Cloudflare delivers the token through
/// its login-helper transfer service, so there is nothing to read out of the browser —
/// which is just as well, because no API would allow it.
@MainActor
final class WebAuthenticationPresenter: NSObject, WebAuthenticationPresenting,
    ASWebAuthenticationPresentationContextProviding
{
    private var session: ASWebAuthenticationSession?

    nonisolated func presentAuthenticationSession(url: URL, callbackURLScheme: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Task { @MainActor in
                self.start(url: url, callbackURLScheme: callbackURLScheme, continuation: continuation)
            }
        }
    }

    private func start(
        url: URL,
        callbackURLScheme: String,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackURLScheme
        ) { _, error in
            if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                continuation.resume(throwing: AccessError.loginCancelled)
            } else {
                // Any other outcome means the browser closed. If the sign-in succeeded,
                // the token arrives through the transfer service, so the caller races
                // this against that poll.
                continuation.resume()
            }
        }
        session.presentationContextProvider = self
        // A private session would discard existing SSO cookies and force a full sign-in,
        // including MFA, on every single connection.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
            continuation.resume(
                throwing: AccessError.loginFailed("the system declined to open the sign-in page")
            )
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }
}
