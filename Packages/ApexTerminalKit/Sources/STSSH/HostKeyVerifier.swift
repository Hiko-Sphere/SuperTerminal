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
    private let authorities: [SSHCertificateAuthority]
    private let log: STLogger
    private let now: @Sendable () -> Date

    public init(
        identity: KnownHostIdentity,
        store: any KnownHostsStore,
        approval: any HostKeyApprovalDelegate,
        certificateAuthorities: [SSHCertificateAuthority] = [],
        log: STLogger = .disabled,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.identity = identity
        self.store = store
        self.approval = approval
        authorities = certificateAuthorities
        self.log = log.child(subsystem: "ssh.hostkey")
        self.now = now
    }

    /// Decides a certified host key against the trusted authorities (D-046).
    ///
    /// A server whose key carries a certificate from an authority this device trusts for
    /// that host name is accepted without anyone comparing a fingerprint — which is the
    /// whole point of host certificates, and a security improvement rather than a
    /// shortcut: comparing fingerprints is the step people skip.
    ///
    /// The certificate is not remembered. It has its own expiry, and storing it would
    /// mean a certificate that has been revoked or has run out keeps working because the
    /// device once saw it.
    ///
    /// Returns `nil` when the key is not certified, or is certified by nobody this device
    /// trusts for this host — in which case the ordinary fingerprint policy applies, and
    /// the user is asked as they always were.
    func certificateVerdict(for key: NIOSSHPublicKey) -> CertificateVerdict? {
        guard let certified = NIOSSHCertifiedPublicKey(key) else { return nil }
        let candidates = authorities.filter { $0.vouchesFor(host: identity.host) }
        guard !candidates.isEmpty else {
            log.info("the server presented a certificate but no authority is trusted for this host", [
                "host": Redactor.hostname(identity.host),
            ])
            return nil
        }
        let signingKeys = candidates.compactMap { try? $0.publicKey() }
        do {
            // NIOSSH checks the signature first, then the principal, the type, the
            // validity window and any critical option it does not understand. Critical
            // options are deliberately not accepted: an option this app does not
            // implement is a restriction the certificate's issuer meant to apply, and
            // ignoring it would be silently widening what the certificate allows.
            _ = try certified.validate(
                principal: identity.host,
                type: .host,
                allowedAuthoritySigningKeys: signingKeys
            )
            log.info("host certificate accepted", [
                "host": Redactor.hostname(identity.host),
                "keyID": certified.keyID,
            ])
            return .trusted
        } catch {
            log.error("host certificate refused", [
                "host": Redactor.hostname(identity.host),
                "error": String(describing: error),
            ])
            return .refused(error)
        }
    }

    enum CertificateVerdict {
        case trusted
        case refused(Error)
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
        // A certificate is decided before anything else: it either settles the question
        // or it is refused outright. Falling back to "ask the user about the fingerprint"
        // after a certificate has failed to validate would turn a definite answer — this
        // certificate is expired, or for another host, or signed by nobody we trust —
        // into a prompt someone will tap through.
        switch certificateVerdict(for: hostKey) {
        case .trusted:
            validationCompletePromise.succeed(())
            return
        case let .refused(error):
            validationCompletePromise.fail(STError(
                category: .hostKey,
                message: String(localized: "The server's certificate was refused.", bundle: .module),
                recoverySuggestion: String(localized: "It may have expired, be issued for another host name, or be signed by an authority this device does not trust.", bundle: .module),
                underlyingDescription: String(describing: error)
            ))
            return
        case nil:
            break
        }

        // No certificate, or one from an authority this device does not trust: fall back
        // to the fingerprint policy — but on the key *inside* the certificate.
        //
        // A certificate is reissued routinely, and every reissue produces a different
        // certified key while the server's actual host key stays put. Remembering the
        // certificate would turn every renewal into "the host key has changed", which is
        // the warning that must mean something. Remembering the key it certifies means
        // the record survives renewals and still changes if the server really is rekeyed.
        let bareKey = NIOSSHCertifiedPublicKey(hostKey).map { $0.key } ?? hostKey
        let presented: SSHHostKey
        do {
            presented = try SSHHostKey(bareKey)
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
