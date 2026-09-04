import Foundation
import STCore

/// Discovers which Cloudflare Access application (if any) protects a hostname.
///
/// The discovery result is the root of trust for the whole Access flow: it decides
/// which auth domain the user will be sent to and which audience the resulting token
/// must carry. It is therefore derived only from a metadata JWT whose signature is
/// verified against the auth domain's published keys, and whose `hostname` claim is
/// checked against the host actually requested. An origin that is not really behind
/// Access cannot forge one, and an Access application cannot claim to be a different
/// application.
public struct AccessDiscovery: Sendable {
    /// The suffix an `auth_domain` claim must have. Only Cloudflare-hosted team
    /// domains are accepted, which is what stops a hostile origin from nominating an
    /// attacker-controlled login domain.
    public static let authDomainSuffix = ".cloudflareaccess.com"

    static let metadataRequestHeader = "cf-access-metadata-request"
    static let metadataResponseHeader = "cf-access-metadata"
    static let metadataMaxAge: TimeInterval = 24 * 60 * 60
    static let metadataAllowedClockSkew: TimeInterval = 5 * 60

    private let http: any HTTPTransport
    private let jwks: JWKSProvider
    private let now: @Sendable () -> Date
    private let log: STLogger

    public init(
        http: any HTTPTransport,
        jwks: JWKSProvider,
        log: STLogger = .disabled,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http
        self.jwks = jwks
        self.log = log.child(subsystem: "access.discovery")
        self.now = now
    }

    /// Result of probing a hostname.
    public enum Probe: Sendable, Equatable {
        /// The hostname is fronted by a Cloudflare Access application.
        case protected(AccessAppInfo)
        /// The hostname answered, but no Access application guards it.
        case unprotected
    }

    /// Probes `host` and returns whether Cloudflare Access protects it.
    ///
    /// A hostname that simply is not behind Access returns ``Probe/unprotected``
    /// rather than throwing, because "plain Cloudflare Tunnel with no Access policy"
    /// is a legitimate configuration this app supports.
    public func probe(host: String, port: Int = 443) async throws -> Probe {
        let url = try Self.originURL(host: host, port: port)
        let response: HTTPResponse
        do {
            response = try await http.send(
                HTTPRequest(
                    url: url,
                    method: .head,
                    headers: [Self.metadataRequestHeader: "true"],
                    followRedirects: false,
                    timeout: 10
                )
            )
        } catch let error as AccessError {
            throw error
        } catch {
            throw AccessError.network(String(describing: error))
        }

        guard let rawJWT = response.header(Self.metadataResponseHeader), !rawJWT.isEmpty else {
            log.debug("no Access metadata header on origin", ["host": Redactor.hostname(host)])
            return .unprotected
        }

        let appInfo = try await verifyMetadata(rawJWT: rawJWT, requestedHost: host)
        log.info("discovered Access application", [
            "host": Redactor.hostname(host),
            "authDomain": appInfo.authDomain,
            "aud": Redactor.shortDigest(appInfo.appAUD),
        ])
        return .protected(appInfo)
    }

    /// Validates a metadata JWT and converts it into an ``AccessAppInfo``.
    func verifyMetadata(rawJWT: String, requestedHost: String) async throws -> AccessAppInfo {
        // Decode once without trusting it, purely to learn which auth domain's keys
        // should be used. Everything read here is re-read from the verified copy.
        let unverified = try ParsedJWT(compact: rawJWT)
        let unverifiedClaims = try unverified.decodePayload(as: AccessMetadataClaims.self)
        let authDomain = try Self.normalizeAuthDomain(unverifiedClaims.authDomain)

        let verified = try await jwks.verify(compactJWT: rawJWT, authDomain: authDomain)
        let claims = try verified.decodePayload(as: AccessMetadataClaims.self)

        // Re-derive the auth domain from the verified payload. Trusting the value we
        // read before verification would let a forged header choose the key set.
        let verifiedAuthDomain = try Self.normalizeAuthDomain(claims.authDomain)
        guard verifiedAuthDomain == authDomain else {
            throw AccessError.signatureVerificationFailed("auth_domain changed between unverified and verified reads")
        }
        guard claims.hostname.lowercased() == requestedHost.lowercased() else {
            throw AccessError.signatureVerificationFailed(
                "metadata hostname does not match the requested host"
            )
        }
        guard claims.type == "match" else {
            throw AccessError.signatureVerificationFailed("metadata type \(claims.type) is not \"match\"")
        }
        guard !claims.aud.isEmpty else {
            throw AccessError.signatureVerificationFailed("metadata aud is empty")
        }
        try validateIssuedAt(claims.iat)

        return AccessAppInfo(
            authDomain: verifiedAuthDomain,
            appAUD: claims.aud,
            // A wildcard Access application reports the pattern in `app_hostname`;
            // using it means one stored token serves every host the application
            // covers, matching how the token is actually scoped.
            appHostname: claims.appHostname.flatMap { $0.isEmpty ? nil : $0 } ?? claims.hostname
        )
    }

    func validateIssuedAt(_ iat: Int64) throws {
        guard iat > 0 else {
            throw AccessError.signatureVerificationFailed("metadata iat is missing or invalid")
        }
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(iat))
        let reference = now()
        if issuedAt < reference.addingTimeInterval(-Self.metadataMaxAge) {
            throw AccessError.signatureVerificationFailed("metadata JWT is older than 24h")
        }
        if issuedAt > reference.addingTimeInterval(Self.metadataAllowedClockSkew) {
            throw AccessError.signatureVerificationFailed("metadata JWT is issued too far in the future")
        }
    }

    static func normalizeAuthDomain(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AccessError.signatureVerificationFailed("metadata auth_domain is empty")
        }
        guard let components = URLComponents(string: "https://\(trimmed)"),
              let host = components.host?.lowercased(), !host.isEmpty
        else {
            throw AccessError.signatureVerificationFailed("metadata auth_domain \(trimmed) is not a valid host")
        }
        guard host.hasSuffix(Self.authDomainSuffix) else {
            throw AccessError.signatureVerificationFailed(
                "metadata auth_domain does not end with \(Self.authDomainSuffix)"
            )
        }
        return host
    }

    static func originURL(host: String, port: Int) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        if port != 443 { components.port = port }
        components.path = "/"
        guard let url = components.url else {
            throw AccessError.metadataUnavailable("\(Redactor.hostname(host)) is not a valid hostname")
        }
        return url
    }
}
