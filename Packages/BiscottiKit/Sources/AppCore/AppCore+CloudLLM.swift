import Foundation
import Intelligence

/// Pavarotti: the cloud LLM that can write summaries, titles and speaker names
/// instead of the local model.
public extension AppCore {
    /// Takes the cloud LLM settings of the live app.
    func useCloudLLM(_ settingsStore: CloudLLMSettingsStore) {
        cloudLLM = settingsStore
        refreshCloudProvider()
    }

    /// Updates whether AI runs go to a cloud provider, after its settings or key changed.
    func refreshCloudProvider() {
        modelManager.cloudProviderActive = cloudLLM?.endpoint() != nil
    }

    /// Saves the provider settings and, when `apiKey` is given, the provider's key
    /// (an empty key removes it).
    func saveCloudLLM(_ settings: CloudLLMSettings, apiKey: String?) throws {
        guard let cloudLLM else { return }
        defer { refreshCloudProvider() }
        cloudLLM.save(settings)
        if let apiKey {
            try cloudLLM.setAPIKey(apiKey, for: settings.provider)
        }
    }

    /// Sends a one-line request to the saved provider.
    /// - Returns: The outcome, for the Settings caption.
    func checkCloudLLM() async -> String {
        guard let endpoint = cloudLLM?.endpoint() else {
            return String(localized: "Fill in the model, the address and the API key first.")
        }
        do {
            let answer = try await ProviderLLMRunner.checkConnection(to: endpoint)
            let start = String(answer.prefix(40))
            return String(localized: "Connected: \(endpoint.model) answered \u{201C}\(start)\u{201D}.")
        } catch {
            return error.localizedDescription
        }
    }
}
