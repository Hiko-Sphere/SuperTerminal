import Foundation
import NIOTransportServices
import STCloudflare
import STCore
import STSSH

/// Opens the SSH connection a host describes — transport, Cloudflare Access, host-key
/// verification, credentials — for every kind of session that needs one.
///
/// The terminal and a remote screen (D-022) go through this one door, so a screen behind
/// the same bastion has the same prompts, the same host-key rules and the same
/// credentials as the shell. There is deliberately no second, simpler path: a simpler
/// path would be one that skips something.
@MainActor
final class HostConnector {
    let host: Host
    /// Raises the decisions only a person can make — a new host key, a password — and
    /// waits for the answer.
    let prompts: PromptCoordinator

    private let group: NIOTSEventLoopGroup
    private let vault: CredentialVault
    private let knownHosts: any KnownHostsStore
    private let log: STLogger
    /// The saved record for a key, which says where its private half lives (D-049) and
    /// carries the certificate an authority issued for it (D-046).
    private let keyRecord: @Sendable (UUID) -> StoredKey?
    /// Authorities trusted to vouch for servers, so a certified host key needs no
    /// fingerprint comparison.
    private let authorities: [SSHCertificateAuthority]
    /// Resolves a saved connection by identifier, for the jump chain (D-047).
    private let hostByID: @Sendable (UUID) -> Host?

    init(
        host: Host,
        group: NIOTSEventLoopGroup,
        vault: CredentialVault,
        knownHosts: any KnownHostsStore,
        log: STLogger,
        prompts: PromptCoordinator,
        keyRecord: @escaping @Sendable (UUID) -> StoredKey? = { _ in nil },
        certificateAuthorities: [SSHCertificateAuthority] = [],
        hostByID: @escaping @Sendable (UUID) -> Host? = { _ in nil }
    ) {
        self.host = host
        self.group = group
        self.vault = vault
        self.knownHosts = knownHosts
        self.log = log
        self.prompts = prompts
        self.keyRecord = keyRecord
        authorities = certificateAuthorities
        self.hostByID = hostByID
    }

    /// Connects and authenticates, naming each step through `progress` as it happens.
    ///
    /// A connection with jump hosts is opened one hop at a time (D-047), each hop a full
    /// SSH connection in its own right — its own credentials, its own host key checked
    /// against its own record. The final connection then travels inside the last hop, so
    /// the bastion carries the traffic without being able to read it.
    func connect(progress: @escaping @MainActor (String) -> Void) async throws -> SSHConnection {
        var carrier: SSHConnection?
        for hop in jumpChain() {
            progress(String(localized: "Connecting through \(hop.name)"))
            do {
                let connection = try await open(hop, over: carrier, progress: { _ in })
                if let carrier { await connection.adopt(carrier: carrier) }
                carrier = connection
            } catch {
                // Which hop failed is the whole question when a chain does not come up,
                // and "the connection could not be established" answers none of it.
                await carrier?.close()
                throw Self.failure(at: hop, error: error)
            }
        }
        do {
            let connection = try await open(host, over: carrier, progress: progress)
            if let carrier { await connection.adopt(carrier: carrier) }
            return connection
        } catch {
            await carrier?.close()
            throw error
        }
    }

    /// The saved connections to hop through, first hop first.
    ///
    /// A chain that names a connection twice — or names itself — would otherwise recurse
    /// until the app ran out of something. Each identifier is used once, and only the
    /// chain the final connection names is followed: a hop's own jump list is ignored, so
    /// the chain is exactly what the user can see in the editor rather than something
    /// assembled from several records.
    private func jumpChain() -> [Host] {
        var seen: Set<UUID> = [host.id]
        var chain: [Host] = []
        for id in host.jumpHosts ?? [] {
            guard !seen.contains(id), let hop = hostByID(id) else { continue }
            seen.insert(id)
            chain.append(hop)
        }
        return chain
    }

    private func open(
        _ host: Host,
        over carrier: SSHConnection?,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> SSHConnection {
        // A connection saved without a user name is asked for one before anything is
        // opened (D-024); the answer lives as long as this attempt.
        let username = try await resolveUsername(for: host)
        let transport: any ByteStreamTransport
        if let carrier {
            // A jump reaches the far server through a channel the previous hop opens, so
            // the host's own transport setting does not apply — there is nothing to dial.
            transport = JumpTransport(
                through: carrier,
                to: TransportEndpoint(host: host.hostname, port: host.port),
                carrierDescription: Redactor.hostname(host.hostname)
            )
        } else {
            transport = try await makeTransport(for: host, progress: progress)
        }
        progress(String(localized: "Exchanging keys"))

        let approval: any HostKeyApprovalDelegate = Self.automaticHostKeyTrust
            ? TrustOnFirstUseApproval()
            : prompts
        let verifier = HostKeyVerifier(
            identity: host.knownHostIdentity,
            store: knownHosts,
            approval: approval,
            certificateAuthorities: authorities,
            log: log
        )
        let credentials = try await resolveCredentials(username: username, for: host)

        let prompts = prompts
        let hostname = host.hostname
        return try await SSHConnection.connect(
            transport: transport,
            configuration: SSHConnectionConfiguration(
                username: username,
                credentials: credentials,
                knownHostIdentity: host.knownHostIdentity,
                // Nothing stored left and the server takes a password: ask the person.
                passwordProvider: { username in
                    await prompts.requestPasswordIfWanted(username: username, host: hostname)
                },
                // And when the server would rather ask its own questions — a one-time
                // code, an expired password — put them to the person as they were written
                // (D-051).
                keyboardInteractiveResponder: { challenge in
                    await prompts.requestKeyboardInteractiveAnswers(host: hostname, challenge: challenge)
                },
                // The agent, when this connection was set up to offer one (D-052).
                agent: try await resolveAgent(for: host)
            ),
            hostKeyVerifier: verifier,
            eventLoop: group.next(),
            log: log
        )
    }

    /// Says which hop failed, keeping the original reason.
    static func failure(at hop: Host, error: Error) -> STError {
        let underlying = error as? STError
        return STError(
            category: underlying?.category ?? .network,
            message: String(localized: "Could not connect through \(hop.name)."),
            recoverySuggestion: underlying?.message,
            underlyingDescription: underlying?.underlyingDescription ?? String(describing: error)
        )
    }

    private func makeTransport(for host: Host, progress: @escaping @MainActor (String) -> Void) async throws -> any ByteStreamTransport {
        switch host.transport {
        case .directTCP:
            return DirectTCPTransport(
                endpoint: TransportEndpoint(host: host.hostname, port: host.port),
                log: log
            )
        case let .cloudflare(jumpDestination):
            progress(String(localized: "Checking Cloudflare Access"))
            // Every Access failure already knows how to describe itself; without this
            // translation they all reached the user as "The connection could not be
            // established", because `TerminalSession` only recognises `STError` and wraps
            // anything else. "No Access application was found for this hostname" and "your
            // session has expired" are the same generic sentence otherwise (D-026).
            let credential: AccessCredential
            do {
                credential = try await resolveAccessCredential(for: host, progress: progress)
            } catch let error as AccessError {
                throw error.stError
            }
            // For a Cloudflare connection the port is the edge's: 443 unless the
            // hostname was published on one of Cloudflare's other HTTPS ports.
            return CloudflareCarrierTransport(
                configuration: .init(
                    host: host.hostname,
                    port: host.port,
                    jumpDestination: jumpDestination,
                    userAgent: Self.userAgent
                ),
                credential: credential,
                log: log
            )
        }
    }

    private func resolveAccessCredential(for host: Host, progress: @escaping @MainActor (String) -> Void) async throws -> AccessCredential {
        // The same steps a remote screen takes to reach its own tunnel (D-029).
        try await AccessCredentialResolver(
            hostname: host.hostname,
            port: host.port,
            usesServiceToken: host.usesServiceToken,
            serviceToken: { [vault, host] in try vault.loadServiceToken(hostID: host.id) },
            vault: vault,
            log: log
        ).credential(progress: progress)
    }

    private func resolveUsername(for host: Host) async throws -> String {
        let saved = host.username.trimmingCharacters(in: .whitespaces)
        if !saved.isEmpty { return saved }
        return try await prompts.requestUsername(host: host.hostname)
    }

    /// Builds the agent this connection will answer with, or `nil` when forwarding is off.
    ///
    /// Only keys the connection already uses are offered. That is the narrowest thing that
    /// is still useful: forwarding exists so a `git push` on the server can use a key from
    /// the phone, and handing over *every* key the device holds would let one server ask to
    /// sign for every other.
    private func resolveAgent(for host: Host) async throws -> SSHAgent? {
        guard host.isForwardingAgent else { return nil }

        var identities: [SSHAgent.Identity] = []
        for reference in host.credentials {
            guard case let .privateKey(id) = reference, let record = keyRecord(id) else { continue }
            let material: SSHPrivateKeyMaterial
            if record.isHeldInSecureEnclave {
                // A Secure Enclave key is the interesting case: the server gets signatures
                // from a key that has never existed outside this device's hardware.
                guard let blob = try? vault.loadSecureEnclaveKey(id: id),
                      let enclave = try? SecureEnclaveSSHKey.material(
                          blob: blob,
                          comment: record.name,
                          authenticationPrompt: nil
                      )
                else { continue }
                material = enclave
            } else {
                guard let pem = try? vault.loadPrivateKey(id: id, prompt: nil),
                      let inspection = try? OpenSSHPrivateKeyParser.inspect(pem: pem),
                      !inspection.isEncrypted,
                      let parsed = try? OpenSSHPrivateKeyParser.parse(pem: pem)
                else { continue }
                material = parsed
            }
            identities.append(.init(key: material.key, comment: record.name))
        }

        guard !identities.isEmpty else {
            log.info("agent forwarding is on but no usable key is attached to this connection")
            return nil
        }
        return SSHAgent(identities: identities, log: log)
    }

    private func resolveCredentials(username: String, for host: Host) async throws -> [SSHCredential] {
        // Nothing saved: offer `none`, which makes the server say what it takes; the
        // chain then asks for a password if that is among them (D-024).
        guard !host.credentials.isEmpty else { return [.none] }
        var credentials: [SSHCredential] = []
        for reference in host.credentials {
            switch reference {
            case let .privateKey(id):
                let record = keyRecord(id)
                let material: SSHPrivateKeyMaterial
                if record?.isHeldInSecureEnclave == true {
                    // Nothing to unlock and nothing to parse: the private half is in the
                    // enclave and stays there.
                    do {
                        let blob = try vault.loadSecureEnclaveKey(id: id)
                        if record?.requiresBiometrics == true {
                            // Asked for here, before the connection is opened. The enclave
                            // would otherwise raise its sheet at the moment it signs —
                            // inside the handshake, on a NIO event loop shared with every
                            // other session, which would sit blocked for as long as the
                            // person took to answer.
                            let context = try await SecureEnclaveSSHKey.authenticatedContext(
                                reason: String(localized: "Use the key for \(host.name)")
                            )
                            material = try SecureEnclaveSSHKey.material(
                                blob: blob,
                                comment: record?.name,
                                context: context
                            )
                        } else {
                            material = try SecureEnclaveSSHKey.material(
                                blob: blob,
                                comment: record?.name,
                                authenticationPrompt: nil
                            )
                        }
                    } catch let error as SecureEnclaveKeyError {
                        // Translated here rather than left to the generic handler: an
                        // enclave key that has stopped working needs the sentence that
                        // says why and what to do, not "the connection could not be
                        // established" with an enum case underneath it.
                        throw error.stError
                    }
                } else {
                    let pem = try vault.loadPrivateKey(
                        id: id,
                        prompt: String(localized: "Unlock the key for \(host.name)")
                    )
                    let inspection = try OpenSSHPrivateKeyParser.inspect(pem: pem)
                    if inspection.isEncrypted {
                        let passphrase = try await prompts.requestPassphrase(keyName: host.name)
                        material = try OpenSSHPrivateKeyParser.parse(pem: pem, passphrase: passphrase)
                    } else {
                        material = try OpenSSHPrivateKeyParser.parse(pem: pem)
                    }
                }
                // A key with a certificate is offered with it. An expired certificate is
                // left off rather than offered: the server would refuse it, and burning
                // an attempt against `MaxAuthTries` to be told so helps nobody. The bare
                // key still goes, because a server may know it directly.
                if let certificate = record?.certificate, certificate.isValid() {
                    credentials.append(.certifiedKey(material, certificate))
                } else {
                    credentials.append(.privateKey(material))
                }
            case .password:
                if let stored = try vault.loadPassword(hostID: host.id) {
                    credentials.append(.password(Redacted(stored, label: "ssh-password")))
                } else {
                    let password = try await prompts.requestPassword(
                        username: username,
                        host: host.hostname
                    )
                    credentials.append(.password(Redacted(password, label: "ssh-password")))
                }
            case .none:
                credentials.append(.none)
            }
        }
        return credentials
    }

    static let userAgent = AccessCredentialResolver.userAgent

    /// Whether to accept a first-seen host key without asking.
    ///
    /// Only ever true in a Debug build driven by an automated UI run, where a modal sheet
    /// would block the very screen the run exists to exercise. A release build has no code
    /// path that sets it, so a real user is always asked.
    private static var automaticHostKeyTrust: Bool {
        #if DEBUG
        UITestSeeding.trustsHostKeysAutomatically
        #else
        false
        #endif
    }
}
