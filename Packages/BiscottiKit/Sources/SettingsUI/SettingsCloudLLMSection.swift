import AppCore
import DesignSystem
import Intelligence
import SwiftUI

/// Pavarotti: who writes summaries, titles and speaker names: the local model or a
/// cloud API (Claude or an OpenAI-compatible server).
struct CloudLLMSettingsSection: View {
    static let title = String(localized: "AI Provider")

    let appCore: AppCore
    private let store: CloudLLMSettingsStore
    @State private var settings: CloudLLMSettings
    @State private var apiKey = ""
    @State private var hasKey: Bool
    @State private var message: String?
    @State private var isChecking = false

    init(appCore: AppCore, store: CloudLLMSettingsStore) {
        self.appCore = appCore
        self.store = store
        let loaded = store.load()
        _settings = State(initialValue: loaded)
        _hasKey = State(initialValue: store.hasAPIKey(for: loaded.provider))
    }

    var body: some View {
        Section(Self.title) {
            Picker("Summaries, titles and speakers", selection: providerBinding) {
                Text("Local model on this Mac").tag(LLMProvider.local)
                Text("Claude (Anthropic API)").tag(LLMProvider.anthropic)
                Text("OpenAI-compatible API").tag(LLMProvider.openAICompatible)
            }
            switch settings.provider {
            case .local:
                EmptyView()
            case .anthropic:
                TextField("Model", text: $settings.anthropicModel, prompt: Text(CloudLLMSettings.defaultAnthropicModel))
                keyField
            case .openAICompatible:
                TextField("Address", text: $settings.openAIBaseURL, prompt: Text(CloudLLMSettings.defaultOpenAIBaseURL))
                TextField("Model", text: $settings.openAIModel, prompt: Text("Model name"))
                keyField
            }
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                if settings.provider != .local {
                    HStack(spacing: Tokens.spacingSM) {
                        Button("Save") { save() }
                        Button("Test Connection") { check() }
                            .disabled(isChecking)
                        Spacer()
                    }
                }
                Text(message ?? caption)
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
        }
    }

    private var keyField: some View {
        LabeledContent("API Key") {
            HStack(spacing: Tokens.spacingSM) {
                SecureField("API Key", text: $apiKey, prompt: Text(hasKey ? "Saved in the keychain" : "Paste the key"))
                    .labelsHidden()
                    .onSubmit { save() }
                if hasKey {
                    Button("Remove") { removeKey() }
                }
            }
        }
    }

    private var caption: String {
        switch settings.provider {
        case .local:
            String(localized: "Uses the downloaded model under AI Enhancements. Nothing leaves this Mac.")
        case .anthropic, .openAICompatible:
            String(localized: "Each meeting\u{2019}s transcript and calendar details are sent to the provider to write its summary, title and speaker names. Recording and transcription stay on this Mac. The key is kept in the keychain.")
        }
    }

    private var providerBinding: Binding<LLMProvider> {
        Binding(
            get: { settings.provider },
            set: { provider in
                settings.provider = provider
                hasKey = store.hasAPIKey(for: provider)
                apiKey = ""
                message = nil
                save(includingKey: false)
            }
        )
    }

    private func save(includingKey: Bool = true) {
        let key = includingKey && !apiKey.isEmpty ? apiKey : nil
        do {
            try appCore.saveCloudLLM(settings, apiKey: key)
            if key != nil {
                apiKey = ""
                hasKey = store.hasAPIKey(for: settings.provider)
                message = String(localized: "Saved.")
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try appCore.saveCloudLLM(settings, apiKey: "")
            hasKey = false
            message = String(localized: "The API key was removed.")
        } catch {
            message = error.localizedDescription
        }
    }

    private func check() {
        save()
        isChecking = true
        message = String(localized: "Testing\u{2026}")
        Task {
            message = await appCore.checkCloudLLM()
            isChecking = false
        }
    }
}
