import Foundation

/// What the user is asking for. The three shapes cover what people ask a terminal for:
/// how to do something here, what this output means, and why this went wrong.
enum AssistantTask: String, CaseIterable, Sendable, Identifiable {
    case howTo, explain, diagnose
    var id: String { rawValue }

    var title: String {
        switch self {
        case .howTo: String(localized: "How do I…")
        case .explain: String(localized: "Explain this")
        case .diagnose: String(localized: "What went wrong")
        }
    }

    var prompt: String {
        switch self {
        case .howTo: String(localized: "What do you want to do on this server?")
        case .explain: String(localized: "Ask about the output shown below, or leave this empty.")
        case .diagnose: String(localized: "Say what you expected, or leave this empty.")
        }
    }
}

/// Where the terminal text in a request came from. Shown to the user before sending.
enum AssistantContextSource: String, CaseIterable, Sendable, Identifiable {
    case selection, screen, none
    var id: String { rawValue }

    var title: String {
        switch self {
        case .selection: String(localized: "Selected text")
        case .screen: String(localized: "Last screen")
        case .none: String(localized: "No terminal text")
        }
    }
}

/// Everything a request carries besides the question, assembled by the view from what
/// the user chose. The assistant never reads the terminal on its own.
struct AssistantContext: Sendable, Equatable {
    var platform: HostPlatform?
    var lastCommand: String?
    var terminalText: String?
    var source: AssistantContextSource = .none

    static let empty = AssistantContext()
}

/// A model-agnostic prompt: the same words go to the on-device model and to a provider.
struct AssistantPrompt: Sendable, Equatable {
    var instructions: String
    var input: String
}

/// Builds the prompt from the task, the question and the context. Pure, so the exact
/// text that leaves the device is testable.
enum AssistantPromptBuilder {
    /// Terminal text longer than this is cut from the top: the most recent lines are the
    /// ones that matter, and a provider bills by the token.
    static let contextCharacterLimit = 6_000

    static func build(task: AssistantTask, question: String, context: AssistantContext) -> AssistantPrompt {
        var instructions = """
        You help someone working in an SSH terminal from an iPhone or iPad. Answer briefly \
        and concretely. Put every command you suggest in its own fenced code block \
        (```sh), one command per line, with nothing else in the block. Never suggest \
        commands that destroy data without saying so first. Do not invent output.
        """
        if let platform = context.platform {
            instructions += " The server runs \(platformName(platform)); use that system's commands and paths."
        } else {
            instructions += " The server's operating system is unknown; say if a command depends on it."
        }

        var input = ""
        switch task {
        case .howTo:
            input += "Task: \(question.isEmpty ? "(no question given)" : question)\n"
        case .explain:
            input += "Explain the terminal output below" + (question.isEmpty ? ".\n" : ". Question: \(question)\n")
        case .diagnose:
            input += "Something went wrong in the terminal output below. Find the cause and how to fix it"
                + (question.isEmpty ? ".\n" : ". Expected: \(question)\n")
        }
        if let command = context.lastCommand, !command.isEmpty {
            input += "Last command run: `\(command)`\n"
        }
        if let text = context.terminalText, !text.isEmpty {
            let trimmed = tail(of: text, limit: contextCharacterLimit)
            input += "\nTerminal text (\(context.source.title.lowercased())):\n```\n\(trimmed)\n```\n"
        }
        return AssistantPrompt(instructions: instructions, input: input)
    }

    /// The end of `text`, cut on a line boundary, no longer than `limit` characters.
    static func tail(of text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.suffix(limit)
        if let newline = cut.firstIndex(of: "\n") { return String(cut[cut.index(after: newline)...]) }
        return String(cut)
    }

    private static func platformName(_ platform: HostPlatform) -> String {
        // English on purpose: this goes to the model, not to the user.
        switch platform {
        case .macOS: "macOS"
        case .linux: "Linux"
        case .windows: "Windows (OpenSSH; the shell is cmd or PowerShell)"
        case .bsd: "BSD"
        case .other: "a Unix-like system that is not macOS or Linux"
        }
    }
}

/// A reply as the user sees it: the prose, and the commands the model put in fences —
/// each a single line, so inserting one never runs anything.
struct AssistantReply: Sendable, Equatable {
    var text: String
    var commands: [String]

    static let empty = AssistantReply(text: "", commands: [])
}

enum AssistantReplyParser {
    /// Commands are lines inside fenced blocks. Prose outside fences is not a command
    /// even when it looks like one; a fence is the model saying "run this".
    static func parse(_ text: String) -> AssistantReply {
        var commands: [String] = []
        var inFence = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard inFence else { continue }
            let command = line.trimmingCharacters(in: .whitespaces)
            if command.isEmpty || command.hasPrefix("#") { continue }
            // A "$ " prompt copied into the fence is decoration, not part of the command.
            let stripped = command.hasPrefix("$ ") ? String(command.dropFirst(2)) : command
            if !commands.contains(stripped) { commands.append(stripped) }
        }
        return AssistantReply(text: text, commands: commands)
    }
}
