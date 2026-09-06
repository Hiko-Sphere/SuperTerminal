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

    init(
        host: Host,
        group: NIOTSEventLoopGroup,
        vault: CredentialVault,
        knownHosts: any KnownHostsStore,
        log: STLogger,
        prompts: PromptCoordinator
    ) {
        self.host = host
        self.group = group
        self.vault = vault
        self.knownHosts = knownHosts
        self.log = log
        self.prompts = prompts
    }

    /// Connects and authenticates, naming each step through `progress` as it happens.
    func connect(progress: @escaping @MainActor (String) -> Void) async throws -> SSHConnection {
        // A connection saved without a user name is asked for one before anything is
        // opened (D-024); the answer lives as long as this attempt.
        let username = try await resolveUsername()
        let transport = try await makeTransport(progress: progress)
        progress(String(localized: "Exchanging keys"))

        let approval: any HostKeyApprovalDelegate = Self.automaticHostKeyTrust
            ? TrustOnFirstUseApproval()
            : prompts
        let verifier = HostKeyVerifier(
            identity: host.knownHostIdentity,
            store: knownHosts,
            approval: approval,
            log: log
        )
        let credentials = try await resolveCredentials(username: username)

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
                }
            ),
            hostKeyVerifier: verifier,
            eventLoop: group.next(),
            log: log
        )
    }

    private func makeTransport(progress: @escaping @MainActor (String) -> Void) async throws -> any ByteStreamTransport {
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
                credential = try await resolveAccessCredential(progress: progress)
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

    private func resolveAccessCredential(progress: @escaping @MainActor (String) -> Void) async throws -> AccessCredential {
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

    private func resolveUsername() async throws -> String {
        let saved = host.username.trimmingCharacters(in: .whitespaces)
        if !saved.isEmpty { return saved }
        return try await prompts.requestUsername(host: host.hostname)
    }

    private func resolveCredentials(username: String) async throws -> [SSHCredential] {
        // Nothing saved: offer `none`, which makes the server say what it takes; the
        // chain then asks for a password if that is among them (D-024).
        guard !host.credentials.isEmpty else { return [.none] }
        var credentials: [SSHCredential] = []
        for reference in host.credentials {
            switch reference {
            case let .privateKey(id):
                let pem = try vault.loadPrivateKey(
                    id: id,
                    prompt: String(localized: "Unlock the key for \(host.name)")
                )
                let inspection = try OpenSSHPrivateKeyParser.inspect(pem: pem)
                if inspection.isEncrypted {
                    let passphrase = try await prompts.requestPassphrase(keyName: host.name)
                    credentials.append(.privateKey(
                        try OpenSSHPrivateKeyParser.parse(pem: pem, passphrase: passphrase)
                    ))
                } else {
                    credentials.append(.privateKey(try OpenSSHPrivateKeyParser.parse(pem: pem)))
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
