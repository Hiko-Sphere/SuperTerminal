import Foundation
import NIOCore
import NIOTransportServices
import STCloudflare
import STCore
import STSFTP
import STSSH
import STSecureStore

/// One SSH connection, opened on demand, for one domain in Files.
///
/// Two rules shape this type, and both are about what it must *not* do.
///
/// It never asks anyone anything. The extension is launched by the system, often while
/// the user is looking at another app entirely, so there is no one to approve a host key,
/// type a password or complete a Face ID check. Every credential it can use is one that
/// needs nobody present; anything else fails as ``FileProviderFailure/needsTheApp`` and
/// Files sends the user to the app, which can ask properly.
///
/// It never claims to stay connected. iOS suspends and kills file provider extensions
/// freely, and an SSH connection dies with the process. So the connection is opened when
/// an operation needs it, reused while the process happens to live, dropped after
/// ``idleTimeout`` of no use, and closed on `invalidate()`. Nothing here pretends a
/// session survives longer than that.
public actor DomainConnection {
    /// How long an unused connection is kept before it is closed.
    ///
    /// Long enough that browsing a few folders reuses one connection; short enough that
    /// a forgotten extension is not holding a server-side session open for nothing.
    public static let idleTimeout: Duration = .seconds(45)

    private let domain: SharedDomain
    private let secureStore: any SecureStore
    private let knownHosts: any KnownHostsStore
    private let group: NIOTSEventLoopGroup
    private let userAgent: String
    private let log: STLogger

    private var connection: SSHConnection?
    private var sftp: SFTPClient?
    /// The login directory, resolved once per connection. `realpath(".")` is a round trip;
    /// every path in the domain is relative to it.
    private var resolvedRoot: String?
    private var idleTask: Task<Void, Never>?
    /// Whether the cached connection is still usable. An `EventLoopFuture` cannot be
    /// asked whether it has completed, so the connection says so itself as it closes —
    /// server timeout, network change, or a suspension long enough to cause either.
    private var alive = false
    private var deathWatch: Task<Void, Never>?

    public init(
        domain: SharedDomain,
        secureStore: any SecureStore,
        knownHosts: any KnownHostsStore,
        group: NIOTSEventLoopGroup,
        userAgent: String,
        log: STLogger = .disabled
    ) {
        self.domain = domain
        self.secureStore = secureStore
        self.knownHosts = knownHosts
        self.group = group
        self.userAgent = userAgent
        self.log = log.child(subsystem: "files.connection")
    }

    /// The remote directory the domain's root shows.
    public func rootPath() async throws -> String {
        if !domain.rootPath.isEmpty { return domain.rootPath }
        if let resolvedRoot { return resolvedRoot }
        let resolved = try await connectedClient().realpath(".")
        resolvedRoot = resolved
        return resolved
    }

    /// Runs one SFTP operation, reconnecting once if the connection died while idle.
    ///
    /// A connection kept across operations will eventually be found dead — the server
    /// timed it out, the network changed, the extension was suspended long enough for
    /// either. That is ordinary, not an error to show the user, so it costs one retry.
    public func withClient<T: Sendable>(_ body: (SFTPClient) async throws -> T) async throws -> T {
        do {
            return try await body(connectedClient())
        } catch {
            guard Self.isDropped(error) else { throw error }
            log.info("retrying after a dropped connection", ["error": String(describing: error)])
            await teardown()
            return try await body(connectedClient())
        }
    }

    /// A connected client, without the retry.
    ///
    /// For an operation that cannot simply be run twice — an upload holds a temporary file
    /// on the server, and the connection that died cannot be asked to tidy it up — the
    /// caller does its own recovery and needs to see the failure rather than have it
    /// quietly repeated underneath.
    public func liveClient() async throws -> SFTPClient {
        try await connectedClient()
    }

    /// Whether a failure means the connection is gone rather than the operation refused.
    ///
    /// This is ordinary on a device: the server timed the session out, the network
    /// changed, or the extension was suspended long enough for either.
    public static func isDropped(_ error: Error) -> Bool {
        if case SFTPError.channelClosed = error { return true }
        if let error = error as? STError { return error.category == .sshChannel || error.category == .network }
        return false
    }

    /// Drops the current connection, so the next use opens a new one.
    public func disconnect() async {
        await teardown()
    }

    public func shutdown() async {
        idleTask?.cancel()
        idleTask = nil
        await teardown()
    }

    // MARK: - Connecting

    private func connectedClient() async throws -> SFTPClient {
        scheduleIdleClose()
        if let sftp, alive { return sftp }
        await teardown()

        let credentials = try loadCredentials()
        let transport = try await makeTransport()
        let verifier = HostKeyVerifier(
            identity: domain.knownHostIdentity,
            store: knownHosts,
            // Refuses both the unknown host and the changed one. Approving either is a
            // decision for a person looking at a fingerprint, and there is no person
            // here. A provider that quietly accepted would make the app's careful
            // host-key handling worthless — the weakest door is the one that counts.
            approval: RefusingApproval(),
            log: log
        )
        let connection = try await SSHConnection.connect(
            transport: transport,
            configuration: SSHConnectionConfiguration(
                username: domain.username,
                credentials: credentials,
                knownHostIdentity: domain.knownHostIdentity,
                // No provider: an exhausted credential list fails here rather than
                // waiting for an answer that cannot come.
                passwordProvider: nil
            ),
            hostKeyVerifier: verifier,
            eventLoop: group.next(),
            log: log
        )
        let client = try await connection.openSFTP()
        self.connection = connection
        sftp = client
        alive = true
        deathWatch = Task { [weak self] in
            await connection.waitUntilClosed()
            await self?.markDead()
        }
        return client
    }

    private func makeTransport() async throws -> any ByteStreamTransport {
        switch domain.transport {
        case .directTCP:
            return DirectTCPTransport(
                endpoint: TransportEndpoint(host: domain.hostname, port: domain.port),
                log: log
            )
        case let .cloudflare(jumpDestination):
            return CloudflareCarrierTransport(
                configuration: .init(
                    host: domain.hostname,
                    port: domain.port,
                    jumpDestination: jumpDestination,
                    userAgent: userAgent
                ),
                credential: try await accessCredential(),
                log: log
            )
        }
    }

    /// The Cloudflare Access credential, if one can be had without a browser.
    ///
    /// A service token always can. A browser session can only be reused while the token
    /// it produced is still valid — signing in again means presenting a web view, which
    /// an extension cannot do, so an expired session sends the user to the app.
    private func accessCredential() async throws -> AccessCredential {
        let http = URLSessionHTTPTransport(userAgent: userAgent)
        let jwks = JWKSProvider(http: http)
        let discovery = AccessDiscovery(http: http, jwks: jwks, log: log)
        switch try await discovery.probe(host: domain.hostname, port: domain.port) {
        case .unprotected:
            return .none
        case let .protected(appInfo):
            if let token = try? loadServiceToken() {
                return .serviceToken(token)
            }
            let stored = try? secureStore.getIfPresent(
                SecureStoreKey(service: SecureStoreServices.accessTokens, account: appInfo.storageIdentifier)
            )
            if let stored, let raw = String(data: stored, encoding: .utf8),
               let validated = try? await AccessTokenValidator(jwks: jwks).validate(rawToken: raw, appInfo: appInfo),
               !validated.isExpired() {
                return .userToken(validated)
            }
            throw FileProviderFailure.needsTheApp(reason: String(
                localized: "The Cloudflare Access session for this server has expired.",
                bundle: .module
            ))
        }
    }

    private func loadServiceToken() throws -> AccessServiceToken {
        guard let data = try secureStore.getIfPresent(
            SecureStoreKey(service: SecureStoreServices.serviceTokens, account: domain.id.uuidString)
        ) else { throw SecureStoreError.itemNotFound }
        let stored = try JSONDecoder().decode(StoredServiceToken.self, from: data)
        return AccessServiceToken(clientID: stored.clientID, clientSecret: stored.secret)
    }

    /// Mirrors what `CredentialVault` writes. The shape is part of the on-disk contract
    /// between the two processes, so it is spelled out rather than shared by accident.
    private struct StoredServiceToken: Codable { var clientID: String; var secret: String }

    private func loadCredentials() throws -> [SSHCredential] {
        var credentials: [SSHCredential] = []
        for reference in domain.credentials {
            switch reference {
            case let .privateKey(id):
                // `prompt: nil` puts the Keychain in non-interactive mode, so a key the
                // user chose to protect with Face ID fails here instead of raising a
                // sheet from a background process.
                guard let data = try? secureStore.get(
                    SecureStoreKey(service: SecureStoreServices.privateKeys, account: id.uuidString),
                    prompt: nil
                ), let pem = String(data: data, encoding: .utf8) else {
                    throw FileProviderFailure.needsTheApp(reason: String(
                        localized: "This connection's key can only be unlocked in the app.",
                        bundle: .module
                    ))
                }
                guard let inspection = try? OpenSSHPrivateKeyParser.inspect(pem: pem), !inspection.isEncrypted else {
                    throw FileProviderFailure.needsTheApp(reason: String(
                        localized: "This connection's key needs its passphrase, which only the app can ask for.",
                        bundle: .module
                    ))
                }
                credentials.append(.privateKey(try OpenSSHPrivateKeyParser.parse(pem: pem)))
            case .storedPassword:
                guard let data = try? secureStore.getIfPresent(
                    SecureStoreKey(service: SecureStoreServices.passwords, account: domain.id.uuidString)
                ), let password = String(data: data, encoding: .utf8) else {
                    throw FileProviderFailure.needsTheApp(reason: String(
                        localized: "No password is saved for this server on this device.",
                        bundle: .module
                    ))
                }
                credentials.append(.password(Redacted(password, label: "ssh-password")))
            }
        }
        guard !credentials.isEmpty else {
            throw FileProviderFailure.needsTheApp(reason: String(
                localized: "This connection has no credential that can be used without you.",
                bundle: .module
            ))
        }
        return credentials
    }

    // MARK: - Lifetime

    private func scheduleIdleClose() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: DomainConnection.idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.teardown()
        }
    }

    private func markDead() {
        alive = false
    }

    private func teardown() async {
        let client = sftp
        let connection = self.connection
        deathWatch?.cancel()
        deathWatch = nil
        sftp = nil
        self.connection = nil
        resolvedRoot = nil
        alive = false
        await client?.close()
        await connection?.close()
    }
}

/// Refuses every host key decision, because there is nobody here to make one.
struct RefusingApproval: HostKeyApprovalDelegate {
    func approveUnknownHost(identity: KnownHostIdentity, key: SSHHostKey) async -> Bool { false }
    func approveChangedHost(identity: KnownHostIdentity, expected: SSHHostKey, presented: SSHHostKey) async -> Bool { false }
}
