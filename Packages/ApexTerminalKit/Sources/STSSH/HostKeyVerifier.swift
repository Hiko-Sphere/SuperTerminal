import Foundation
import NIOCore
import NIOSSH
import STCore

/// Asked to decide what to do about a host key that is not already trusted.
///
/// The app implements this by presenting a sheet; automated tests implement it with a
/// fixed policy. There is no implementation that silently accepts a **changed** key —
/// that decision always reaches a human.
public protocol HostKeyApprovalDelegate: Sendable {
    /// A host is being contacted for the first time. Return `true` to trust and
    /// remember the key.
    func approveUnknownHost(identity: KnownHostIdentity, key: SSHHostKey) async -> Bool

    /// The host's key does not match the one recorded. Return `true` only if the user
    /// explicitly accepted the replacement after being shown both fingerprints.
    func approveChangedHost(
        identity: KnownHostIdentity,
        expected: SSHHostKey,
        presented: SSHHostKey
    ) async -> Bool
}

/// Applies ApexTerminal's host key policy and bridges it to NIOSSH.
///
/// Policy, in order:
///
/// 1. A key that matches the stored entry is accepted, and `lastSeen` is refreshed.
/// 2. An unseen identity is referred to the delegate (trust on first use, confirmed).
/// 3. A key that differs from the stored one is a **hard stop**: the connection is
///    refused unless the user explicitly accepts the replacement. This is the case
///    that indicates either a server rebuild or an active machine-in-the-middle, and
///    conflating it with case 2 is what makes many mobile SSH clients unsafe.
public final class HostKeyVerifier: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let identity: KnownHostIdentity
    private let store: any KnownHostsStore
    private let approval: any HostKeyApprovalDelegate
    private let log: STLogger
    private let now: @Sendable () -> Date

    public init(
        identity: KnownHostIdentity,
        store: any KnownHostsStore,
        approval: any HostKeyApprovalDelegate,
        log: STLogger = .disabled,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.identity = identity
        self.store = store
        self.approval = approval
        self.log = log.child(subsystem: "ssh.hostkey")
        self.now = now
    }

    /// Classifies a presented key without applying any side effects. Exposed so the
    /// policy can be unit tested independently of NIOSSH and of the UI.
    public func classify(_ presented: SSHHostKey) async throws -> HostKeyVerdict {
        guard let existing = try await store.entry(for: identity) else {
            return .unknown(identity, presented)
        }
        if existing.key == presented {
            return .known(existing)
        }
        return .changed(expected: existing, presented: presented)
    }

    /// Runs the full policy, including asking the user and persisting the decision.
    public func verify(_ presented: SSHHostKey) async throws {
        switch try await classify(presented) {
        case var .known(entry):
            entry.lastSeen = now()
            try await store.store(entry)
            log.debug("host key matched", ["host": Redactor.hostname(identity.host)])

        case let .unknown(identity, key):
            guard await approval.approveUnknownHost(identity: identity, key: key) else {
                // Interpolated rather than left inside the sentence: the command has to
                // reach the user exactly as typed, and a translator editing the string
                // would otherwise be free to reword the flag or the path.
                let command = "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
                throw STError(
                    category: .hostKey,
                    message: String(localized: "Connection cancelled because the host key was not accepted.", bundle: .module),
                    recoverySuggestion: String(
                        localized: "Verify the fingerprint on the server with `\(command)`, then connect again.",
                        bundle: .module
                    )
                )
            }
            let entry = KnownHostEntry(identity: identity, key: key, firstSeen: now(), lastSeen: now())
            try await store.store(entry)
            log.info("host key trusted on first use", ["host": Redactor.hostname(identity.host)])

        case let .changed(expected, presented):
            log.error("host key changed", ["host": Redactor.hostname(identity.host)])
            guard await approval.approveChangedHost(
                identity: identity,
                expected: expected.key,
                presented: presented
            ) else {
                throw STError(
                    category: .hostKey,
                    message: String(localized: "The host key for \(identity.displayName) has changed.", bundle: .module),
                    recoverySuggestion: String(localized: "Do not continue unless you know the server was rebuilt or rekeyed. If you did not expect this, someone may be intercepting the connection.", bundle: .module),
                    underlyingDescription: "expected \(expected.key.fingerprintSHA256), got \(presented.fingerprintSHA256)"
                )
            }
            let entry = KnownHostEntry(
                identity: identity,
                key: presented,
                firstSeen: expected.firstSeen,
                lastSeen: now()
            )
            try await store.store(entry)
            log.warning("host key replacement accepted by user", ["host": Redactor.hostname(identity.host)])
        }
    }

    // MARK: - NIOSSHClientServerAuthenticationDelegate

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented: SSHHostKey
        do {
            presented = try SSHHostKey(hostKey)
        } catch {
            validationCompletePromise.fail(error)
            return
        }
        Task {
            do {
                try await verify(presented)
                validationCompletePromise.succeed(())
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }
}

/// Approval policy for automated tests and CI: accepts a first-seen key, never accepts
/// a changed one. Deliberately lives in the shipping module so its behaviour is
/// covered by the same tests as the app's policy — but the app never installs it.
public struct TrustOnFirstUseApproval: HostKeyApprovalDelegate {
    public init() {}

    public func approveUnknownHost(identity: KnownHostIdentity, key: SSHHostKey) async -> Bool { true }

    public func approveChangedHost(
        identity: KnownHostIdentity,
        expected: SSHHostKey,
        presented: SSHHostKey
    ) async -> Bool { false }
}

/// Approval policy that pins to an expected fingerprint supplied out of band.
public struct PinnedFingerprintApproval: HostKeyApprovalDelegate {
    private let expectedFingerprint: String

    public init(expectedFingerprint: String) {
        self.expectedFingerprint = expectedFingerprint
    }

    public func approveUnknownHost(identity: KnownHostIdentity, key: SSHHostKey) async -> Bool {
        key.fingerprintSHA256 == expectedFingerprint
    }

    public func approveChangedHost(
        identity: KnownHostIdentity,
        expected: SSHHostKey,
        presented: SSHHostKey
    ) async -> Bool {
        presented.fingerprintSHA256 == expectedFingerprint
    }
}
