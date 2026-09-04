import Foundation
import STCore

/// Turns a raw Cloudflare Access token string into a ``ValidatedAccessToken``.
///
/// Every check here exists to stop a specific failure mode:
///
/// * **Signature** — a token that is not signed by the team's published keys is a
///   forgery; without this check an attacker who can write to storage or intercept
///   the transfer response could inject one.
/// * **Audience** — Access issues one token per application. Sending an
///   `app-a` token to `app-b` is the token-confusion attack that makes a single
///   compromised low-privilege app a key to every other host in the account.
/// * **Issuer** — pins the token to the auth domain the verified metadata named.
/// * **Lifetime** — `exp` and `nbf`, with a small leeway so a token that expires
///   mid-handshake is refused before it is sent rather than after.
public struct AccessTokenValidator: Sendable {
    /// Tokens within this window of expiry are treated as already expired, so a
    /// connection is never started with a credential that will die during the SSH
    /// handshake.
    public static let expiryLeeway: TimeInterval = 30

    private let jwks: JWKSProvider
    private let now: @Sendable () -> Date

    public init(jwks: JWKSProvider, now: @escaping @Sendable () -> Date = { Date() }) {
        self.jwks = jwks
        self.now = now
    }

    public func validate(rawToken: String, appInfo: AccessAppInfo) async throws -> ValidatedAccessToken {
        let verified = try await jwks.verify(compactJWT: rawToken, authDomain: appInfo.authDomain)
        let claims = try verified.decodePayload(as: AccessTokenClaims.self)

        guard claims.aud.contains(appInfo.appAUD) else {
            throw AccessError.audienceMismatch(expected: appInfo.appAUD, found: claims.aud.values)
        }
        try validateIssuer(claims.iss, authDomain: appInfo.authDomain)
        try validateLifetime(claims)

        return ValidatedAccessToken(token: rawToken, claims: claims, appInfo: appInfo)
    }

    func validateIssuer(_ issuer: String?, authDomain: String) throws {
        guard let issuer, !issuer.isEmpty else {
            throw AccessError.issuerMismatch(expected: authDomain, found: issuer)
        }
        // Access spells the issuer as an https URL; accept a bare host too rather
        // than failing a valid token on a formatting difference.
        let issuerHost: String
        if let components = URLComponents(string: issuer), let host = components.host {
            issuerHost = host.lowercased()
        } else {
            issuerHost = issuer.lowercased()
        }
        guard issuerHost == authDomain.lowercased() else {
            throw AccessError.issuerMismatch(expected: authDomain, found: issuer)
        }
    }

    func validateLifetime(_ claims: AccessTokenClaims) throws {
        let reference = now()
        let expiry = Date(timeIntervalSince1970: TimeInterval(claims.exp))
        guard reference.addingTimeInterval(Self.expiryLeeway) < expiry else {
            throw AccessError.tokenExpired(expiry)
        }
        if let nbf = claims.nbf {
            let notBefore = Date(timeIntervalSince1970: TimeInterval(nbf))
            guard reference.addingTimeInterval(Self.expiryLeeway) >= notBefore else {
                throw AccessError.tokenNotYetValid(notBefore)
            }
        }
    }
}
