import Dictation
import Foundation
import Intelligence
import LocalLLM

/// Pavarotti: structures a braindump dictation with the AI model. The downloaded local
/// model goes first; without one, the cloud provider from Settings does it.
struct BraindumpStructurer: DictationTextStructuring {
    /// Runs sessions on the local model.
    let local: any LLMRunning
    /// Runs sessions with the cloud provider.
    let cloud: any LLMRunning
    /// The downloaded local model, `nil` when there is none.
    let localModel: @MainActor @Sendable () -> URL?
    /// Whether a cloud provider is set up completely.
    let cloudAvailable: @Sendable () -> Bool

    /// The largest context the local model gets for a braindump (tokens).
    static let maximumContext = 32 * 1024
    /// The smallest answer budget (tokens), so short dictations still fit headings and lists.
    static let minimumAnswer = 1024
    static let maximumAnswer = 8192

    func structure(_ text: String) async throws -> String {
        let messages = [LLMMessage.system(Braindump.systemPrompt), .user(Braindump.userPrompt(for: text))]
        if let model = await localModel() {
            return try await local.withSession(model: model, config: .modelOnly) { session in
                try await Self.generate(messages, in: session)
            }
        }
        guard cloudAvailable() else { throw BraindumpError.noModel }
        return try await cloud.withSession(model: ModelManager.cloudPlaceholderModelURL, config: .modelOnly) { session in
            try await Self.generate(messages, in: session)
        }
    }

    /// Sizes the context for the prompt plus an answer about twice its length, then generates.
    static func generate(_ messages: [LLMMessage], in session: any LLMSession) async throws -> String {
        let promptTokens = try await session.countTokens(messages: messages)
        let answerTokens = min(maximumAnswer, max(minimumAnswer, promptTokens * 2))
        let contextSize = min(maximumContext, promptTokens + answerTokens + 256)
        try await session.reconfigure(contextSize: contextSize)
        let options = GenerationOptions(maxTokens: answerTokens, temperature: 0.3, thinking: .off)
        return try await session.generate(messages: messages, options: options)
    }
}

public extension AppCore {
    /// The structurer the app hands to dictation for braindumps.
    func braindumpStructurer() -> any DictationTextStructuring {
        let manager = modelManager
        let settings = cloudLLM
        return BraindumpStructurer(
            local: LiveLLMRunner(),
            cloud: ProviderLLMRunner(local: LiveLLMRunner(), endpoint: { settings?.endpoint() }),
            localModel: { manager.activeModelURL() },
            cloudAvailable: { settings?.endpoint() != nil }
        )
    }
}
