import Foundation
import STCore

/// Presents a system web-authentication session and reports when the user dismissed
/// it. The app layer implements this with `ASWebAuthenticationSession`; tests supply
/// a driver that performs the browser half of the exchange programmatically.
///
/// The presenter deliberately does **not** return a token. Cloudflare Access delivers
/// credentials out-of-band through the transfer service, never through the web
/// session's callback URL, so no code here ever tries to read a cookie or JWT out of
/// the authentication browser — which the platform does not permit anyway.
public protocol WebAuthenticationPresenting: Sendable {
    /// Opens `url` in a system authentication session.
    ///
    /// Returns when the user dismisses the session. Throws
    /// ``AccessError/loginCancelled`` if the user explicitly cancelled. The caller
    /// races this against the transfer poll and cancels the task that loses.
    func presentAuthenticationSession(url: URL, callbackURLScheme: String) async throws
}

/// Runs the Cloudflare Access interactive login and returns a validated app token.
///
/// ## Why polling rather than a redirect callback
///
/// Cloudflare's CLI login endpoint (`/cdn-cgi/access/cli`) encrypts the resulting
/// tokens to an ephemeral Curve25519 public key that the client generates per login
/// and passes in the request. After the identity provider round-trip — including any
/// SSO and MFA steps — the edge posts the encrypted blob to the login-helper transfer
/// service, keyed by that public key. The client retrieves and decrypts it.
///
/// This is what makes Access viable on iOS at all: the app never needs to read a
/// cookie or JWT out of the authentication browser, which `ASWebAuthenticationSession`
/// does not allow and which no supported API exposes.
///
/// ## Why the ephemeral key is also the CSRF defence
///
/// The public key is 32 bytes of fresh randomness generated inside this process and
/// never persisted. It is simultaneously the transfer-service lookup key and the
/// encryption target, so a credential can only be retrieved and read by the exact
/// login attempt that created it. A racing or replayed login cannot substitute its
/// own result, and the token that comes back is still signature-, audience-,
/// issuer- and lifetime-checked before it is used.
public struct AccessLoginService: Sendable {
    public struct Configuration: Sendable {
        /// Cloudflare's login-helper transfer service.
        public var transferServiceBaseURL: URL
        /// Custom URL scheme handed to the web authentication session. The flow never
        /// redirects to it; it exists because the platform API requires one.
        public var callbackURLScheme: String
        /// Ask Cloudflare to close its success interstitial automatically.
        public var autoCloseInterstitial: Bool
        /// How long to keep polling before giving up.
        public var pollTimeout: TimeInterval
        /// Delay between transfer-service polls.
        public var pollInterval: TimeInterval
        /// Timeout for a single poll request.
        public var pollRequestTimeout: TimeInterval

        public init(
            transferServiceBaseURL: URL = URL(string: "https://login.cloudflareaccess.org/")!,
            callbackURLScheme: String = "apexterminal",
            autoCloseInterstitial: Bool = true,
            pollTimeout: TimeInterval = 300,
            pollInterval: TimeInterval = 1.5,
            pollRequestTimeout: TimeInterval = 20
        ) {
            self.transferServiceBaseURL = transferServiceBaseURL
            self.callbackURLScheme = callbackURLScheme
            self.autoCloseInterstitial = autoCloseInterstitial
            self.pollTimeout = pollTimeout
            self.pollInterval = pollInterval
            self.pollRequestTimeout = pollRequestTimeout
        }
    }

    /// Tokens returned by the transfer service.
    struct TransferPayload: Decodable, Sendable {
        let appToken: String
        let orgToken: String?

        enum CodingKeys: String, CodingKey {
            case appToken = "app_token"
            case orgToken = "org_token"
        }
    }

    private let http: any HTTPTransport
    private let presenter: any WebAuthenticationPresenting
    private let validator: AccessTokenValidator
    private let configuration: Configuration
    private let log: STLogger
    private let box: any BoxCrypto

    public init(
        http: any HTTPTransport,
        presenter: any WebAuthenticationPresenting,
        validator: AccessTokenValidator,
        configuration: Configuration = Configuration(),
        box: any BoxCrypto = SodiumBoxCrypto(),
        log: STLogger = .disabled
    ) {
        self.http = http
        self.presenter = presenter
        self.validator = validator
        self.configuration = configuration
        self.box = box
        self.log = log.child(subsystem: "access.login")
    }

    /// Performs an interactive login for `appInfo` against `originHost` and returns a
    /// fully validated application token.
    public func login(appInfo: AccessAppInfo, originHost: String, originPort: Int = 443) async throws -> LoginResult {
        let keyPair = try box.generateKeyPair()
        let publicKeyString = Base64URLPadded.encode(keyPair.publicKey)

        let loginURL = try Self.buildLoginURL(
            originHost: originHost,
            originPort: originPort,
            appAUD: appInfo.appAUD,
            ephemeralPublicKey: publicKeyString,
            autoCloseInterstitial: configuration.autoCloseInterstitial
        )
        log.info("starting Access login", [
            "authDomain": appInfo.authDomain,
            "aud": Redactor.shortDigest(appInfo.appAUD),
        ])

        let payload = try await withThrowingTaskGroup(of: TransferPayload?.self) { group in
            group.addTask {
                try await presenter.presentAuthenticationSession(
                    url: loginURL,
                    callbackURLScheme: configuration.callbackURLScheme
                )
                // The user dismissed the browser. If the token already arrived the
                // poll task wins the race; otherwise this is a real cancellation.
                return nil
            }
            group.addTask {
                try await pollTransferService(keyPair: keyPair, publicKeyString: publicKeyString)
            }

            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let result { return result }
                // The browser closed first. Give the poll a brief grace period: the
                // interstitial auto-closes a moment before the blob is retrievable.
                if let late = try await group.next() {
                    if let late { return late }
                }
                throw AccessError.loginCancelled
            }
            throw AccessError.loginCancelled
        }

        let validated = try await validator.validate(
            rawToken: payload.appToken,
            appInfo: appInfo
        )
        log.info("Access login completed", [
            "aud": Redactor.shortDigest(appInfo.appAUD),
            "expiresIn": "\(Int(validated.expiresAt.timeIntervalSinceNow))s",
        ])
        return LoginResult(token: validated, organizationToken: payload.orgToken.map { Redacted($0, label: "cf-org-token") })
    }

    public struct LoginResult: Sendable {
        public let token: ValidatedAccessToken
        /// The team-wide token, usable to mint app tokens for other applications in
        /// the same organisation without another browser round-trip.
        public let organizationToken: Redacted<String>?
    }

    private func pollTransferService(keyPair: BoxKeyPair, publicKeyString: String) async throws -> TransferPayload {
        let url = configuration.transferServiceBaseURL
            .appendingPathComponent("transfer")
            .appendingPathComponent(publicKeyString)
        let deadline = Date().addingTimeInterval(configuration.pollTimeout)

        while Date() < deadline {
            try Task.checkCancellation()
            let response: HTTPResponse
            do {
                response = try await http.send(
                    HTTPRequest(url: url, method: .get, timeout: configuration.pollRequestTimeout)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Transient network trouble during a multi-minute SSO flow is normal;
                // keep polling until the overall deadline instead of failing the login.
                log.debug("transfer poll failed, retrying", ["error": String(describing: error)])
                try await Task.sleep(for: .seconds(configuration.pollInterval))
                continue
            }

            if response.statusCode >= 500 {
                throw AccessError.loginFailed("transfer service returned HTTP \(response.statusCode)")
            }
            if response.statusCode == 200, !response.body.isEmpty {
                return try decryptTransferPayload(response: response, keyPair: keyPair)
            }
            try await Task.sleep(for: .seconds(configuration.pollInterval))
        }
        throw AccessError.transferTimedOut
    }

    func decryptTransferPayload(response: HTTPResponse, keyPair: BoxKeyPair) throws -> TransferPayload {
        guard let servicePublicKeyString = response.header("service-public-key"),
              let servicePublicKey = Base64URLPadded.decode(servicePublicKeyString)
        else {
            throw AccessError.decryptionFailed("transfer response carried no service-public-key header")
        }
        guard let base64 = String(data: response.body, encoding: .utf8),
              let sealed = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw AccessError.decryptionFailed("transfer response body was not base64")
        }
        guard sealed.count > 24 else {
            throw AccessError.decryptionFailed("transfer payload is too short to contain a nonce")
        }
        guard let opened = box.open(
            nonceAndCiphertext: sealed,
            senderPublicKey: servicePublicKey,
            recipientSecretKey: keyPair.secretKey
        ) else {
            throw AccessError.decryptionFailed("authenticated decryption of the transfer payload failed")
        }
        do {
            return try JSONDecoder().decode(TransferPayload.self, from: opened)
        } catch {
            throw AccessError.decryptionFailed("transfer payload was not the expected JSON: \(error)")
        }
    }

    /// Builds the `/cdn-cgi/access/cli` URL that starts the login.
    ///
    /// The parameter set matches what Cloudflare's own client sends, because the
    /// endpoint's behaviour — in particular pushing the encrypted credential to the
    /// login-helper rather than returning it inline — is selected by
    /// `edge_token_transfer`.
    static func buildLoginURL(
        originHost: String,
        originPort: Int,
        appAUD: String,
        ephemeralPublicKey: String,
        autoCloseInterstitial: Bool
    ) throws -> URL {
        var redirect = URLComponents()
        redirect.scheme = "https"
        redirect.host = originHost
        if originPort != 443 { redirect.port = originPort }
        redirect.path = "/"
        redirect.queryItems = [
            URLQueryItem(name: "aud", value: appAUD),
            URLQueryItem(name: "token", value: ephemeralPublicKey),
        ]
        guard let redirectURL = redirect.url else {
            throw AccessError.loginFailed("could not build the Access redirect URL")
        }

        var login = redirect
        login.path = "/cdn-cgi/access/cli"
        var items = [
            URLQueryItem(name: "aud", value: appAUD),
            URLQueryItem(name: "token", value: ephemeralPublicKey),
            URLQueryItem(name: "redirect_url", value: redirectURL.absoluteString),
            URLQueryItem(name: "send_org_token", value: "true"),
            URLQueryItem(name: "edge_token_transfer", value: "true"),
        ]
        if autoCloseInterstitial {
            items.append(URLQueryItem(name: "close_interstitial", value: "true"))
        }
        login.queryItems = items
        guard let url = login.url else {
            throw AccessError.loginFailed("could not build the Access login URL")
        }
        return url
    }
}

/// Go's `base64.URLEncoding`: URL-safe alphabet **with** padding.
///
/// The transfer service keys credentials by the exact string the client sent, so the
/// padding characters are part of the identifier and must be preserved.
public enum Base64URLPadded {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    public static func decode(_ string: String) -> Data? {
        let normalised = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: normalised)
    }
}
