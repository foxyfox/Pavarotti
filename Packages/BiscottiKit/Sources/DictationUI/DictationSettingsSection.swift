import CohereTranscribe
import DesignSystem
import Dictation
import SwiftUI

/// The Dictation part of Settings: shortcut, language, microphone (also for meetings), model,
/// Accessibility access, sounds, audio ducking, the recording bubble and the dictionary.
public struct DictationSettingsSection: View {
    let controller: DictationController

    public static let title = String(localized: "Dictation")
    static let soundsTitle = String(localized: "Dictation Sounds")

    public init(controller: DictationController) {
        self.controller = controller
    }

    public var body: some View {
        Section {
            Toggle("Push-to-talk dictation", isOn: enabledBinding)
            if controller.settings.isEnabled {
                ShortcutRecorderRow(controller: controller)
                Picker("Mode", selection: modeBinding) {
                    ForEach(DictationShortcutMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                languageRows
            }
            // Meeting recordings use the same microphone, so it stays visible without dictation.
            microphoneRows
            if controller.settings.isEnabled {
                modelRows
                accessibilityRow
                VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                    Toggle("Restore the clipboard after pasting", isOn: restoresClipboardBinding)
                    Text("Dictated text is pasted through the clipboard. Your previous clipboard comes back right after.")
                        .font(Tokens.metadataFont)
                        .foregroundStyle(Tokens.secondaryText)
                }
            }
        } header: {
            HStack {
                Text(Self.title)
                Spacer()
                Text("Runs locally on this Mac.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
        }
        .onAppear {
            controller.refreshAccessibility()
            controller.refreshMicrophones()
            controller.refreshCustomSounds()
        }

        if controller.settings.isEnabled {
            Section(Self.soundsTitle) {
                soundRows
                duckingRows
            }
            Section(Self.bubbleTitle) {
                bubbleRows
            }
            DictionarySection(controller: controller)
        }
    }

    // MARK: - Model

    @ViewBuilder
    private var modelRows: some View {
        Picker("Model", selection: modelBinding) {
            ForEach(CohereModel.all) { model in
                Text("\(model.displayName), \(Self.size(of: model))").tag(model.id)
            }
        }
        HStack {
            engineStatus
            Spacer()
            engineAction
        }
        retentionRows
    }

    @ViewBuilder
    private var engineStatus: some View {
        switch controller.engineState {
        case .notInstalled:
            statusText(verbatim: Self.notInstalledText(controller.installPlan))
        case let .installing(fraction):
            ProgressView(value: fraction) {
                statusText("Installing \(Int(fraction * 100)) %")
            }
        case .installed:
            statusText("Installed. Loads when dictation is on.")
        case .loading:
            HStack(spacing: Tokens.spacingXS) {
                ProgressView().controlSize(.small)
                statusText("Loading the model\u{2026}")
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.sage)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.warningOchre)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private var engineAction: some View {
        switch controller.engineState {
        case .notInstalled:
            Button("Install") { controller.installModel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .failed:
            Button("Try Again") {
                if controller.isModelInstalled {
                    controller.retryEngine()
                } else {
                    controller.installModel()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .installing, .installed, .loading, .ready:
            EmptyView()
        }
    }

    // MARK: - Accessibility

    private var accessibilityRow: some View {
        HStack {
            Image(
                systemName: controller.isAccessibilityTrusted
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(controller.isAccessibilityTrusted ? .sage : .warningOchre)
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("Accessibility")
                Text("Needed to notice the shortcut and to paste into other apps.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
            Spacer()
            if !controller.isAccessibilityTrusted {
                Button("Grant Access") { controller.requestAccessibility() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Open Settings") { SystemAccessibilityTrust.openSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    func statusText(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)
    }

    /// A caption that is already in the app's language.
    func statusText(verbatim text: String) -> some View {
        Text(text)
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)
    }

    static func notInstalledText(_ plan: DictationInstallPlan) -> String {
        if plan.copiesModelFromTypeWhisper {
            return String(localized: "Not installed. TypeWhisper already has this model, so it is copied instead of downloaded.")
        }
        let size = ByteCountFormatter.string(fromByteCount: plan.downloadBytes, countStyle: .file)
        return String(localized: "Not installed. Installing downloads \(size).")
    }

    static func size(of model: CohereModel) -> String {
        ByteCountFormatter.string(fromByteCount: model.asset.size, countStyle: .file)
    }
}

// MARK: - Bindings

extension DictationSettingsSection {
    var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.isEnabled },
            set: { newValue in controller.update { $0.isEnabled = newValue } }
        )
    }

    var modeBinding: Binding<DictationShortcutMode> {
        Binding(
            get: { controller.settings.mode },
            set: { newValue in controller.update { $0.mode = newValue } }
        )
    }

    var modelBinding: Binding<String> {
        Binding(
            get: { controller.settings.modelID },
            set: { newValue in controller.update { $0.modelID = newValue } }
        )
    }

    var restoresClipboardBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.restoresClipboard },
            set: { newValue in controller.update { $0.restoresClipboard = newValue } }
        )
    }
}
