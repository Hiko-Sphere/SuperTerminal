import Crypto
import Foundation
import STCore
import _CryptoExtras

/// A JSON Web Key as served by `https://<auth-domain>/cdn-cgi/access/certs`.
///
/// Cloudflare Access signs both the application token and the app-metadata token
/// with RSA keys published at that endpoint, so RSA is the only key type this
/// decoder accepts. Anything else is rejected rather than silently skipped, because
/// a key type we cannot check is indistinguishable from a key we must not trust.
struct JSONWebKey: Decodable, Sendable {
    let kty: String
    let kid: String?
    let alg: String?
    let use: String?
    let n: String?
    let e: String?
}

struct JSONWebKeySet: Decodable, Sendable {
    let keys: [JSONWebKey]
}

/// Verifies compact JWS signatures against a JWKS.
public struct JWSVerifier: Sendable {
    /// The only signature algorithm Cloudflare Access uses, and therefore the only
    /// one accepted. Pinning this closes the "alg: none" and algorithm-substitution
    /// classes of JWT attack outright.
    static let supportedAlgorithm = "RS256"

    private let keys: [JSONWebKey]

    init(keys: [JSONWebKey]) {
        self.keys = keys
    }

    /// Returns the parsed JWT if — and only if — its signature verifies against one
    /// of the key set's keys.
    func verify(_ jwt: ParsedJWT) throws -> ParsedJWT {
        guard jwt.header.alg == Self.supportedAlgorithm else {
            throw AccessError.signatureVerificationFailed(
                "unsupported JWS alg \(jwt.header.alg); only \(Self.supportedAlgorithm) is accepted"
            )
        }

        // When the header names a key, only that key may be used. Falling back to
        // "try them all" after a kid miss would let a rotated-out key stay usable.
        let candidates: [JSONWebKey]
        if let kid = jwt.header.kid {
            candidates = keys.filter { $0.kid == kid }
            guard !candidates.isEmpty else {
                throw AccessError.signatureVerificationFailed("no JWKS key matches kid \(kid)")
            }
        } else {
            candidates = keys
        }

        let digest = SHA256.hash(data: jwt.signingInput)
        let signature = _RSA.Signing.RSASignature(rawRepresentation: jwt.signature)

        for key in candidates {
            guard key.kty == "RSA", let n = key.n, let e = key.e,
                  let modulus = Base64URL.decode(n), let exponent = Base64URL.decode(e)
            else { continue }
            guard let publicKey = try? _RSA.Signing.PublicKey(n: modulus, e: exponent) else { continue }
            if publicKey.isValidSignature(signature, for: digest, padding: .insecurePKCS1v1_5) {
                return jwt
            }
        }
        throw AccessError.signatureVerificationFailed("signature did not verify against any published key")
    }
}

/// Fetches and caches the JWKS for a Cloudflare Access auth domain.
///
/// The cache exists so that every connection attempt does not re-fetch keys, and so
/// that a brief network failure cannot silently downgrade verification. A cache miss
/// on an unknown `kid` triggers exactly one rate-limited refresh, which is how key
/// rotation is picked up without giving an attacker an unbounded refresh trigger.
public actor JWKSProvider {
    public struct Configuration: Sendable {
        public var cacheTTL: TimeInterval
        public var minimumRefreshInterval: TimeInterval
        public var maximumResponseBytes: Int
        public var requestTimeout: TimeInterval

        public init(
            cacheTTL: TimeInterval = 24 * 60 * 60,
            minimumRefreshInterval: TimeInterval = 60,
            maximumResponseBytes: Int = 1 << 20,
            requestTimeout: TimeInterval = 10
        ) {
            self.cacheTTL = cacheTTL
            self.minimumRefreshInterval = minimumRefreshInterval
            self.maximumResponseBytes = maximumResponseBytes
            self.requestTimeout = requestTimeout
        }
    }

    private struct CacheEntry {
        var keys: [JSONWebKey]
        var fetchedAt: Date
    }

    private let http: any HTTPTransport
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private var cache: [String: CacheEntry] = [:]

    public init(
        http: any HTTPTransport,
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http
        self.configuration = configuration
        self.now = now
    }

    /// Verifies `compactJWT` against `authDomain`'s key set, refreshing the cache at
    /// most once if the signature does not verify against the cached keys.
    public func verify(compactJWT: String, authDomain: String) async throws -> ParsedJWT {
        let jwt = try ParsedJWT(compact: compactJWT)

        if let cached = cache[authDomain], now().timeIntervalSince(cached.fetchedAt) < configuration.cacheTTL {
            if let verified = try? JWSVerifier(keys: cached.keys).verify(jwt) {
                return verified
            }
            guard now().timeIntervalSince(cached.fetchedAt) >= configuration.minimumRefreshInterval else {
                throw AccessError.signatureVerificationFailed(
                    "signature did not verify and the key set was refreshed too recently to retry"
                )
            }
        }

        let keys = try await fetchKeys(authDomain: authDomain)
        cache[authDomain] = CacheEntry(keys: keys, fetchedAt: now())
        return try JWSVerifier(keys: keys).verify(jwt)
    }

    private func fetchKeys(authDomain: String) async throws -> [JSONWebKey] {
        guard var components = URLComponents(string: "https://\(authDomain)") else {
            throw AccessError.metadataUnavailable("auth domain \(authDomain) is not a valid host")
        }
        components.path = "/cdn-cgi/access/certs"
        guard let url = components.url else {
            throw AccessError.metadataUnavailable("could not build a JWKS URL for \(authDomain)")
        }

        let response = try await http.send(
            HTTPRequest(
                url: url,
                method: .get,
                headers: [:],
                body: nil,
                followRedirects: false,
                timeout: configuration.requestTimeout
            )
        )
        guard response.statusCode == 200 else {
            throw AccessError.metadataUnavailable("JWKS endpoint returned HTTP \(response.statusCode)")
        }
        guard response.body.count <= configuration.maximumResponseBytes else {
            throw AccessError.metadataUnavailable("JWKS response exceeded \(configuration.maximumResponseBytes) bytes")
        }
        let set = try JSONDecoder().decode(JSONWebKeySet.self, from: response.body)
        guard !set.keys.isEmpty else {
            throw AccessError.metadataUnavailable("JWKS response contained no keys")
        }
        return set.keys
    }
}
