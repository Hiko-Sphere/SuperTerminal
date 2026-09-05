import Foundation

/// An OpenAI-compatible chat-completions endpoint the user configured. The key is read
/// at request time from the Keychain and put in one header; it is never held in a
/// property, logged, or written anywhere else.
struct ProviderAssistant: AssistantEngine {
    struct Configuration: Sendable, Equatable {
        /// The API's base URL, e.g. `https://api.openai.com/v1`; `/chat/completions` is appended.
        var baseURL: URL
        var model: String
    }

    let configuration: Configuration
    let keyProvider: @Sendable () throws -> String?
    var session: URLSession = .shared

    var displayName: String {
        String(localized: "\(configuration.model) at \(configuration.baseURL.host() ?? configuration.baseURL.absoluteString)")
    }

    /// The exact request that goes out, exposed so a test can read it.
    func makeRequest(for prompt: AssistantPrompt) throws -> URLRequest {
        guard let key = try keyProvider(), !key.isEmpty else { throw AssistantError.missingKey }
        var request = URLRequest(url: configuration.baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": configuration.model,
            "stream": true,
            "messages": [
                ["role": "system", "content": prompt.instructions],
                ["role": "user", "content": prompt.input],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.timeoutInterval = 60
        return request
    }

    func respond(to prompt: AssistantPrompt) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(for: prompt)
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200 ..< 300).contains(status) else {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 4_000 { break } }
                        throw AssistantError.provider(status: status, message: Self.errorMessage(from: body))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let delta = try Self.delta(from: payload), !delta.isEmpty { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The text in one streamed chunk, or nil for a chunk that carries none (role
    /// announcements, finish markers).
    static func delta(from payload: String) throws -> String? {
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AssistantError.badResponse(String(payload.prefix(80)))
        }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else { return nil }
        if let delta = first["delta"] as? [String: Any] { return delta["content"] as? String }
        if let message = first["message"] as? [String: Any] { return message["content"] as? String }
        return nil
    }

    static func errorMessage(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "no details") : String(trimmed.prefix(200))
    }
}
