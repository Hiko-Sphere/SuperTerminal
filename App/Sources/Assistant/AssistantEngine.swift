import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Something that turns a prompt into a stream of text. Two exist: the on-device model
/// and a provider the user configured. Neither is ever simulated.
protocol AssistantEngine: Sendable {
    /// Shown to the user so they know where their text goes.
    var displayName: String { get }
    func respond(to prompt: AssistantPrompt) -> AsyncThrowingStream<String, Error>
}

enum AssistantError: Error, LocalizedError, Equatable {
    case noEngine(reason: String)
    case provider(status: Int, message: String)
    case badResponse(String)
    case missingKey
    /// The on-device model refused or failed; `reason` is the system's own explanation.
    case onDevice(reason: String)

    var errorDescription: String? {
        switch self {
        case let .noEngine(reason): reason
        case let .provider(status, message): String(localized: "The provider answered \(status): \(message)")
        case let .badResponse(detail): String(localized: "The provider's answer could not be read: \(detail)")
        case .missingKey: String(localized: "No API key is stored for the provider.")
        case let .onDevice(reason): String(localized: "The on-device model could not answer: \(reason)")
        }
    }
}

/// Which engine would answer right now, and why none would.
enum AssistantAvailability: Equatable, Sendable {
    case onDevice
    case provider(name: String)
    case unavailable(reason: String)

    var isAvailable: Bool { if case .unavailable = self { return false }; return true }
}

/// Apple's on-device model, where the device is eligible. Answers never leave the device.
#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
struct OnDeviceAssistant: AssistantEngine {
    let displayName = String(localized: "Apple Intelligence on this device")

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Why the model is not available, in the system's own words.
    static var unavailabilityReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible: return String(localized: "This device cannot run Apple Intelligence.")
            case .appleIntelligenceNotEnabled: return String(localized: "Apple Intelligence is turned off in Settings.")
            case .modelNotReady: return String(localized: "The on-device model is still downloading.")
            @unknown default: return String(localized: "The on-device model is not available.")
            }
        }
    }

    func respond(to prompt: AssistantPrompt) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: prompt.instructions)
                    var delivered = ""
                    for try await snapshot in session.streamResponse(to: prompt.input) {
                        let whole = snapshot.content
                        // Snapshots are cumulative; hand on only what is new.
                        if whole.hasPrefix(delivered) {
                            continuation.yield(String(whole.dropFirst(delivered.count)))
                        } else {
                            continuation.yield(whole)
                        }
                        delivered = whole
                    }
                    continuation.finish()
                } catch {
                    // Everything the model throws is the model's failure — including the
                    // bridged error the simulator produces, which is not a `GenerationError`
                    // value and would otherwise pass through unrecognised.
                    continuation.finish(throwing: AssistantError.onDevice(reason: Self.describe(error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The framework's own words where it has them; its case name where it does not.
    /// An error the framework does not explain — seen as "error -1" on a simulator whose
    /// host runs the model — is reported as such rather than as a generic sentence.
    static func describe(_ error: any Error) -> String {
        guard let error = error as? LanguageModelSession.GenerationError else {
            let nsError = error as NSError
            return String(localized: "an error the system did not explain") + " (\(nsError.domain) \(nsError.code))"
        }
        return switch error {
        case let .exceededContextWindowSize(context): String(localized: "the request is too long for the model") + " (\(context.debugDescription))"
        case let .assetsUnavailable(context): String(localized: "the model's files are not available on this device") + " (\(context.debugDescription))"
        case let .guardrailViolation(context): String(localized: "the request was declined by the model's safety rules") + " (\(context.debugDescription))"
        case let .unsupportedGuide(context): String(localized: "unsupported generation guide") + " (\(context.debugDescription))"
        case let .unsupportedLanguageOrLocale(context): String(localized: "the model does not support this language") + " (\(context.debugDescription))"
        case let .decodingFailure(context): String(localized: "the model's answer could not be read") + " (\(context.debugDescription))"
        case let .rateLimited(context): String(localized: "the model is busy; try again in a moment") + " (\(context.debugDescription))"
        case let .concurrentRequests(context): String(localized: "another request is still running") + " (\(context.debugDescription))"
        case let .refusal(_, context): String(localized: "the model declined to answer") + " (\(context.debugDescription))"
        @unknown default: error.errorDescription ?? String(localized: "an error the system did not explain") + " (\(error))"
        }
    }
}
#endif
