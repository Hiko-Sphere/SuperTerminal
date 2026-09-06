import Foundation
import STCloudflare
import STCore

/// Gets the Cloudflare Access credential for one hostname (D-001, D-029).
///
/// Lifted out of `HostConnector` when remote screens learned to reach a tunnel of their
/// own: the steps are identical whether what comes out of the tunnel is SSH or RFB —
/// discover whether the hostname is protected, use a stored token while it is valid, use
/// a service token when the connection is set to, otherwise sign in — and having them in
/// one place is what keeps the two from drifting apart.
@MainActor
struct AccessCredentialResolver {
    /// The Access-protected hostname the tunnel publishes.
    let hostname: String
    /// The port the Cloudflare edge is reached on: 443, or one of its other HTTPS ports.
    let port: Int
    /// Whether this connection signs in with a service token rather than a browser.
    let usesServiceToken: Bool
    /// The service token, looked up wherever this kind of connection keeps it.
    let serviceToken: () throws -> AccessServiceToken?
    let vault: CredentialVault
    let log: STLogger

    static let userAgent = "SuperTerminal/\(Bundle.main.shortVersion) (iOS)"

    func credential(progress: @escaping @MainActor (String) -> Void) async throws -> AccessCredential {
        let http = URLSessionHTTPTransport(userAgent: Self.userAgent)
        let jwks = JWKSProvider(http: http)
        let discovery = AccessDiscovery(http: http, jwks: jwks, log: log)
        let validator = AccessTokenValidator(jwks: jwks)

        switch try await discovery.probe(host: hostname, port: port) {
        case .unprotected:
            // A tunnel without an Access policy is a legitimate configuration; the
            // carrier still works, there is just nothing to authenticate.
            return .none

        case let .protected(appInfo):
            if usesServiceToken {
                guard let token = try serviceToken() else {
                    throw STError(
                        category: .credential,
                        message: String(localized: "This connection is set to use a Cloudflare Access service token, but none is stored on this device."),
                        recoverySuggestion: String(localized: "Edit the connection and enter the service token's client ID and secret. Service tokens stay on the device they were entered on.")
                    )
                }
                return .serviceToken(token)
            }
            if let stored = try? vault.loadAccessToken(appIdentifier: appInfo.storageIdentifier),
               let validated = try? await validator.validate(rawToken: stored, appInfo: appInfo),
               !validated.isExpired() {
                return .userToken(validated)
            }
            progress(String(localized: "Signing in to Cloudflare Access"))
            let login = AccessLoginService(
                http: http,
                presenter: WebAuthenticationPresenter(),
                validator: validator,
                log: log
            )
            let result = try await login.login(appInfo: appInfo, originHost: hostname)
            try? vault.storeAccessToken(
                result.token.token.reveal(),
                appIdentifier: appInfo.storageIdentifier
            )
            return .userToken(result.token)
        }
    }
}
