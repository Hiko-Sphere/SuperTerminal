import Foundation
import Testing
@testable import SuperTerminal

/// The assistant's words are testable because they are pure: what leaves the device is
/// built by one function, and what comes back is read by another. The provider client is
/// exercised against a real local HTTP server speaking the same protocol (D-020).
@Suite("Assistant")
struct AssistantTests {
    @Test("The prompt names the platform, the last command and the chosen text, fenced")
    func promptCarriesWhatTheUserChose() {
        let context = AssistantContext(platform: .linux, lastCommand: "ls -la /var/log", terminalText: "total 0\n-rw-r--r-- 1 root root 0 syslog", source: .screen)
        let prompt = AssistantPromptBuilder.build(task: .explain, question: "why is it empty?", context: context)
        #expect(prompt.instructions.contains("The server runs Linux"))
        #expect(prompt.input.contains("Last command run: `ls -la /var/log`"))
        #expect(prompt.input.contains("Terminal text (last screen):\n```\ntotal 0"))
        #expect(prompt.input.contains("Question: why is it empty?"))
        let unknown = AssistantPromptBuilder.build(task: .howTo, question: "free disk space", context: .empty)
        #expect(unknown.instructions.contains("operating system is unknown"))
        #expect(unknown.input == "Task: free disk space\n")
    }

    @Test("Long terminal text keeps its most recent lines")
    func longContextIsCutFromTheTop() {
        let lines = (1 ... 500).map { "line \($0) " + String(repeating: "x", count: 40) }
        let text = lines.joined(separator: "\n")
        let kept = AssistantPromptBuilder.tail(of: text, limit: 1_000)
        #expect(kept.count <= 1_000)
        #expect(kept.hasPrefix("line "), "the cut lands on a line boundary")
        #expect(kept.hasSuffix(lines.last!))
    }

    @Test("Commands are the lines inside fences, one each, prompts stripped, prose ignored")
    func parserReadsFences() {
        let text = """
        Use du to see what is large:
        ```sh
        $ du -sh /var/log/*
        # then sort
        du -sh /var/log/* | sort -h
        ```
        You could also run `ls -la` but that shows less.
        ```
        df -h
        ```
        """
        let reply = AssistantReplyParser.parse(text)
        #expect(reply.commands == ["du -sh /var/log/*", "du -sh /var/log/* | sort -h", "df -h"])
        #expect(reply.text == text)
        #expect(AssistantReplyParser.parse("no fences here `ls`").commands.isEmpty)
    }

    @Test("The provider client streams deltas, sends the key in one header only, and asks to stream")
    func providerStreamsOverARealSocket() async throws {
        let server = try ChatCompletionsTestServer(behaviour: .stream(["Use ", "`df -h`.", "\n```sh\ndf -h\n```"]))
        defer { server.shutDown() }
        let engine = ProviderAssistant(
            configuration: .init(baseURL: server.baseURL, model: "test-model"),
            keyProvider: { "sk-test-not-a-real-key" }
        )
        var received = ""
        for try await delta in engine.respond(to: AssistantPrompt(instructions: "be brief", input: "disk space?")) {
            received += delta
        }
        #expect(received == "Use `df -h`.\n```sh\ndf -h\n```")
        let request = try #require(server.recordedRequests.first)
        #expect(request.method == "POST")
        #expect(request.path.hasSuffix("/v1/chat/completions"))
        #expect(request.headers.contains { $0.0.lowercased() == "authorization" && $0.1 == "Bearer sk-test-not-a-real-key" })
        #expect(!request.body.contains("sk-test-not-a-real-key"), "the key travels in the header and nowhere else")
        #expect(request.body.contains("\"stream\":true"))
        #expect(request.body.contains("\"model\":\"test-model\""))
        #expect(request.body.contains("disk space?"))
        #expect(AssistantReplyParser.parse(received).commands == ["df -h"])
    }

    @Test("A provider error is reported with its status and message, and a missing key never sends")
    func providerErrorsAreNamed() async throws {
        let server = try ChatCompletionsTestServer(behaviour: .respond(status: 401, body: #"{"error":{"message":"Incorrect API key provided"}}"#))
        defer { server.shutDown() }
        let engine = ProviderAssistant(configuration: .init(baseURL: server.baseURL, model: "m"), keyProvider: { "bad" })
        var thrown: Error?
        do {
            for try await _ in engine.respond(to: AssistantPrompt(instructions: "", input: "x")) {}
        } catch { thrown = error }
        #expect(thrown as? AssistantError == .provider(status: 401, message: "Incorrect API key provided"))

        let keyless = ProviderAssistant(configuration: .init(baseURL: server.baseURL, model: "m"), keyProvider: { nil })
        var keyError: Error?
        do {
            for try await _ in keyless.respond(to: AssistantPrompt(instructions: "", input: "x")) {}
        } catch { keyError = error }
        #expect(keyError as? AssistantError == .missingKey)
        #expect(server.recordedRequests.count == 1, "no request leaves without a key")
    }

    @Test("Chunk payloads are read leniently: role announcements carry no text")
    func deltaParsing() throws {
        #expect(try ProviderAssistant.delta(from: #"{"choices":[{"delta":{"role":"assistant"}}]}"#) == nil)
        #expect(try ProviderAssistant.delta(from: #"{"choices":[{"delta":{"content":"hi"}}]}"#) == "hi")
        #expect(try ProviderAssistant.delta(from: #"{"choices":[]}"#) == nil)
        #expect(throws: AssistantError.self) { try ProviderAssistant.delta(from: "not json") }
    }
}
