import Foundation
import STCore

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
}

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: HTTPMethod
    public var headers: [String: String]
    public var body: Data?
    public var followRedirects: Bool
    public var timeout: TimeInterval

    public init(
        url: URL,
        method: HTTPMethod,
        headers: [String: String] = [:],
        body: Data? = nil,
        followRedirects: Bool = true,
        timeout: TimeInterval = 15
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.followRedirects = followRedirects
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        // HTTP header field names are case-insensitive; normalise once so callers
        // never have to guess how a given server capitalised a header.
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Abstraction over the HTTP client so that Access discovery and login can be driven
/// against a real local HTTPS server in tests without ever relaxing TLS validation in
/// the shipping code path.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// `URLSession`-backed transport used by the app.
///
/// TLS validation is left entirely to the system: there is no
/// `urlSession(_:didReceive:completionHandler:)` override, so no code path in this
/// app can accept an invalid certificate.
public final class URLSessionHTTPTransport: NSObject, HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let userAgent: String

    public init(userAgent: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.userAgent = userAgent
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        // The delegate is installed only to suppress redirect following; it does not
        // implement any authentication-challenge handling, so the system's default
        // certificate validation always applies.
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: delegateQueue)
        super.init()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let session = request.followRedirects ? self.session : Self.nonRedirectingSession(basedOn: self.session)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw AccessError.network("response was not HTTP")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key] = value
                }
            }
            return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let error as AccessError {
            throw error
        } catch {
            throw AccessError.network(String(describing: error))
        }
    }

    private static let redirectBlocker = RedirectBlocker()

    private static func nonRedirectingSession(basedOn session: URLSession) -> URLSession {
        redirectBlocker.session(basedOn: session.configuration)
    }
}

/// Holds a single lazily created `URLSession` whose delegate refuses redirects.
///
/// Cloudflare Access signals "you are not authenticated" with a 302 to
/// `/cdn-cgi/access/login`. Following that redirect would turn a precise,
/// actionable signal into an HTML login page, so discovery must see the 302 itself.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var cached: URLSession?

    func session(basedOn configuration: URLSessionConfiguration) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        cached = session
        return session
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
