import Foundation

/// Pavarotti: where summaries, titles and speaker names are written.
public enum LLMProvider: String, Codable, CaseIterable, Sendable {
    /// The downloaded model, on this Mac.
    case local
    /// Claude through the Anthropic Messages API.
    case anthropic
    /// Any server with an OpenAI-style `/chat/completions` endpoint.
    case openAICompatible

    /// The keychain account of the provider's API key.
    var keychainAccount: String {
        rawValue
    }
}

/// Pavarotti: the cloud LLM choice. Stored as JSON in user defaults like the other
/// Pavarotti settings; API keys live in the keychain, never here.
public struct CloudLLMSettings: Codable, Equatable, Sendable {
    public var provider: LLMProvider = .local
    public var anthropicModel = CloudLLMSettings.defaultAnthropicModel
    public var openAIBaseURL = CloudLLMSettings.defaultOpenAIBaseURL
    public var openAIModel = ""

    public static let defaultAnthropicModel = "claude-opus-5-5"
    public static let defaultOpenAIBaseURL = "https://api.openai.com/v1"

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? container.decodeIfPresent(LLMProvider.self, forKey: .provider)) ?? .local
        anthropicModel = (try? container.decodeIfPresent(String.self, forKey: .anthropicModel)) ?? Self.defaultAnthropicModel
        openAIBaseURL = (try? container.decodeIfPresent(String.self, forKey: .openAIBaseURL)) ?? Self.defaultOpenAIBaseURL
        openAIModel = (try? container.decodeIfPresent(String.self, forKey: .openAIModel)) ?? ""
    }
}

/// Where a cloud AI run goes: everything a request needs.
public struct CloudEndpoint: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case anthropic
        case openAICompatible
    }

    public var kind: Kind
    /// The API root, e.g. `https://api.anthropic.com/v1`.
    public var baseURL: URL
    public var model: String
    /// Empty for OpenAI-compatible servers that need no key.
    public var apiKey: String

    public init(kind: Kind, baseURL: URL, model: String, apiKey: String) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    static let anthropicBaseURL = URL(string: "https://api.anthropic.com/v1")!
}

/// Keeps secrets such as API keys.
public protocol SecretStoring: Sendable {
    func secret(for account: String) -> String?
    /// Saves `secret` for `account`; `nil` or empty removes it.
    func setSecret(_ secret: String?, for account: String) throws
}

/// Loads and saves ``CloudLLMSettings`` and the API keys, and resolves the endpoint
/// AI runs go to.
public final class CloudLLMSettingsStore: @unchecked Sendable {
    public static let settingsKey = "pavarotti.llm.settings"
    // UserDefaults and the keychain are thread-safe.
    private let defaults: UserDefaults
    private let secrets: any SecretStoring

    public init(defaults: UserDefaults = .standard, secrets: any SecretStoring = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    public func load() -> CloudLLMSettings {
        guard let data = defaults.data(forKey: Self.settingsKey),
              let settings = try? JSONDecoder().decode(CloudLLMSettings.self, from: data)
        else {
            return CloudLLMSettings()
        }
        return settings
    }

    public func save(_ settings: CloudLLMSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }

    public func hasAPIKey(for provider: LLMProvider) -> Bool {
        !(secrets.secret(for: provider.keychainAccount) ?? "").isEmpty
    }

    /// Saves the API key of `provider`; an empty key removes it.
    public func setAPIKey(_ key: String, for provider: LLMProvider) throws {
        try secrets.setSecret(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.keychainAccount)
    }

    /// The endpoint AI runs go to; `nil` for the local model or while the chosen
    /// provider is missing its model, address or key.
    public func endpoint() -> CloudEndpoint? {
        Self.endpoint(for: load(), apiKey: { secrets.secret(for: $0.keychainAccount) ?? "" })
    }

    static func endpoint(for settings: CloudLLMSettings, apiKey: (LLMProvider) -> String) -> CloudEndpoint? {
        switch settings.provider {
        case .local:
            return nil
        case .anthropic:
            let model = settings.anthropicModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = apiKey(.anthropic)
            guard !model.isEmpty, !key.isEmpty else { return nil }
            return CloudEndpoint(kind: .anthropic, baseURL: CloudEndpoint.anthropicBaseURL, model: model, apiKey: key)
        case .openAICompatible:
            let model = settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = settings.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()),
                  url.host() != nil
            else {
                return nil
            }
            return CloudEndpoint(kind: .openAICompatible, baseURL: url, model: model, apiKey: apiKey(.openAICompatible))
        }
    }
}
