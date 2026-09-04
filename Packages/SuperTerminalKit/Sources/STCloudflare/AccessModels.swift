import Foundation
import STCore

/// Identity of the Cloudflare Access application guarding a hostname.
///
/// Every field here is learned from a **signature-verified** metadata JWT issued by
/// the Cloudflare edge — never from an unauthenticated redirect — so a hostile origin
/// cannot steer the client at a login domain or audience of its choosing.
public struct AccessAppInfo: Sendable, Equatable, Codable {
    /// The team's auth domain, e.g. `example.cloudflareaccess.com`.
    public let authDomain: String
    /// The Access application audience tag (`aud`). Tokens are scoped to this value.
    public let appAUD: String
    /// The hostname as configured on the Access application, which may be a wildcard.
    public let appHostname: String

    public init(authDomain: String, appAUD: String, appHostname: String) {
        self.authDomain = authDomain
        self.appAUD = appAUD
        self.appHostname = appHostname
    }

    /// Stable identity used as the secure-storage key for tokens belonging to this app.
    public var storageIdentifier: String { "\(appHostname)|\(appAUD)" }
}

/// Claims carried by the `cf-access-metadata` JWT.
struct AccessMetadataClaims: Decodable, Sendable {
    let type: String
    let hostname: String
    let authDomain: String
    let aud: String
    let appHostname: String?
    let iat: Int64

    enum CodingKeys: String, CodingKey {
        case type
        case hostname
        case authDomain = "auth_domain"
        case aud
        case appHostname = "app_hostname"
        case iat
    }
}

/// Claims SuperTerminal validates on an Access application token before it is ever
/// attached to a connection.
public struct AccessTokenClaims: Decodable, Sendable, Equatable {
    public let aud: AudienceClaim
    public let iss: String?
    public let exp: Int64
    public let iat: Int64?
    public let nbf: Int64?
    public let email: String?
    public let sub: String?
    public let type: String?

    public var expiryDate: Date { Date(timeIntervalSince1970: TimeInterval(exp)) }
}

/// A token that has passed audience, issuer and lifetime validation for a specific
/// Access application. The initialiser is internal: the only way to obtain one is
/// through ``AccessTokenValidator``.
public struct ValidatedAccessToken: Sendable {
    public let token: Redacted<String>
    public let claims: AccessTokenClaims
    public let appInfo: AccessAppInfo

    init(token: String, claims: AccessTokenClaims, appInfo: AccessAppInfo) {
        self.token = Redacted(token, label: "cf-access-token")
        self.claims = claims
        self.appInfo = appInfo
    }

    public var expiresAt: Date { claims.expiryDate }

    public func isExpired(now: Date = Date(), leeway: TimeInterval = 30) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }
}

/// A Cloudflare Access service token — the non-interactive credential used by
/// automation. Kept separate from user tokens so the UI can never confuse a shared
/// machine credential with a human session.
public struct AccessServiceToken: Sendable {
    public let clientID: String
    public let clientSecret: Redacted<String>

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = Redacted(clientSecret, label: "cf-access-client-secret")
    }
}

/// How a connection authenticates to Cloudflare Access.
public enum AccessCredential: Sendable {
    /// An interactively obtained, audience-validated user token.
    case userToken(ValidatedAccessToken)
    /// A service token issued by an Access administrator.
    case serviceToken(AccessServiceToken)
    /// The hostname is not protected by Access.
    case none
}

public enum AccessError: Error, Sendable, Equatable {
    case malformedToken(String)
    case metadataUnavailable(String)
    case signatureVerificationFailed(String)
    case audienceMismatch(expected: String, found: [String])
    case issuerMismatch(expected: String, found: String?)
    case tokenExpired(Date)
    case tokenNotYetValid(Date)
    case loginCancelled
    case loginFailed(String)
    case transferTimedOut
    case decryptionFailed(String)
    case accessDenied(String)
    case network(String)

    /// Maps to the shared error vocabulary used by the UI.
    public var stError: STError {
        switch self {
        case let .malformedToken(detail):
            STError(
                category: .access,
                message: "Cloudflare Access returned a token this app could not read.",
                recoverySuggestion: "Sign in to Cloudflare Access again. If it keeps happening, the Access application may be misconfigured.",
                underlyingDescription: detail
            )
        case let .metadataUnavailable(detail):
            STError(
                category: .access,
                message: "No Cloudflare Access application was found for this hostname.",
                recoverySuggestion: "Check the hostname, or turn off Cloudflare Access for this host if it is a plain SSH server.",
                underlyingDescription: detail
            )
        case let .signatureVerificationFailed(detail):
            STError(
                category: .access,
                message: "Could not verify that this hostname is genuinely protected by your Cloudflare team.",
                recoverySuggestion: "Do not enter credentials. Verify the hostname, then try again on a trusted network.",
                underlyingDescription: detail
            )
        case let .audienceMismatch(expected, found):
            STError(
                category: .access,
                message: "The Cloudflare Access token is for a different application.",
                recoverySuggestion: "Sign out of Cloudflare Access for this host and sign in again.",
                underlyingDescription: "expected aud \(expected), token carried \(found.count) audience(s)"
            )
        case let .issuerMismatch(expected, _):
            STError(
                category: .access,
                message: "The Cloudflare Access token was issued by an unexpected team.",
                recoverySuggestion: "Sign out and sign in again with the account that owns this host.",
                underlyingDescription: "expected issuer \(expected)"
            )
        case .tokenExpired:
            STError(
                category: .access,
                message: "Your Cloudflare Access session has expired.",
                recoverySuggestion: "Sign in again to reconnect."
            )
        case .tokenNotYetValid:
            STError(
                category: .access,
                message: "The Cloudflare Access token is not valid yet.",
                recoverySuggestion: "Check that this device's clock is correct, then try again."
            )
        case .loginCancelled:
            STError(category: .cancelled, message: "Cloudflare Access sign-in was cancelled.")
        case let .loginFailed(detail):
            STError(
                category: .access,
                message: "Cloudflare Access sign-in did not complete.",
                recoverySuggestion: "Try signing in again.",
                underlyingDescription: detail
            )
        case .transferTimedOut:
            STError(
                category: .access,
                message: "Timed out waiting for Cloudflare Access sign-in to finish.",
                recoverySuggestion: "Try again and complete the sign-in prompt, including any two-factor step."
            )
        case let .decryptionFailed(detail):
            STError(
                category: .access,
                message: "The Cloudflare Access credential could not be decrypted.",
                recoverySuggestion: "Sign in again. If this repeats, report it — it may indicate a tampered network path.",
                underlyingDescription: detail
            )
        case let .accessDenied(detail):
            STError(
                category: .access,
                message: "Cloudflare Access denied this connection.",
                recoverySuggestion: "Ask your administrator whether your identity is allowed by this application's policy.",
                underlyingDescription: detail
            )
        case let .network(detail):
            STError(
                category: .network,
                message: "Could not reach Cloudflare.",
                recoverySuggestion: "Check your network connection and try again.",
                underlyingDescription: detail
            )
        }
    }
}
