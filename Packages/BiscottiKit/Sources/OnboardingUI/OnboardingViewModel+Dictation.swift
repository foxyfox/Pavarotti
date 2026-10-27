import CohereTranscribe
import Dictation

// Pavarotti: the Cohere Transcribe row on the model step and the Accessibility row on the
// permissions step. Both are left out without dictation (tests and previews).

public extension OnboardingViewModel {
    /// Push-to-talk dictation; `nil` in tests and previews.
    var dictation: DictationController? {
        appCore.dictation
    }

    /// Whether Pavarotti may paste dictated text. `true` without dictation.
    var accessibilityGranted: Bool {
        dictation?.isAccessibilityTrusted ?? true
    }

    /// Shows the system prompt for Accessibility access.
    func requestAccessibility() {
        dictation?.requestAccessibility()
    }

    /// Whether the Cohere model is on disk. `true` without dictation.
    var dictationReady: Bool {
        guard let dictation else { return true }
        switch dictation.engineState {
        case .installed, .loading, .ready:
            return true
        case .failed:
            // A model that is installed but failed to load is still downloaded.
            return dictation.isModelInstalled
        case .notInstalled, .installing:
            return false
        }
    }

    /// Whether the Cohere model is on disk or being installed.
    var dictationStarted: Bool {
        if case .installing = dictation?.engineState {
            return true
        }
        return dictationReady
    }

    /// Whether every model of the step is ready or downloading.
    var allModelsStarted: Bool {
        bothModelsStarted && dictationStarted
    }

    /// Whether every model of the step is ready.
    var allModelsReady: Bool {
        bothModelsReady && dictationReady
    }

    /// The selected Cohere model.
    var dictationModel: CohereModel? {
        dictation.flatMap { CohereModel.model(id: $0.settings.modelID) }
    }

    /// Installs the selected Cohere model, copied from TypeWhisper when it is there.
    func startDictationDownload() {
        dictation?.installModel()
    }

    /// Chooses another Cohere model before installing it.
    func chooseDictationModel(_ model: CohereModel) {
        guard let dictation else { return }
        dictation.update { $0.modelID = model.id }
        dictationFacts?.plan = dictation.installPlan
    }

    /// Prefers a model TypeWhisper already has and reads what installing takes.
    internal func prepareDictationRow(availableBytes: Int64) {
        guard let dictation else { return }
        dictation.preferTypeWhisperModel()
        dictationFacts = DictationRowFacts(plan: dictation.installPlan, availableBytes: availableBytes)
    }

    internal func dictationRowState() -> ModelRowState {
        guard let dictation else { return .ready }
        return Self.dictationRowState(engine: dictation.engineState, isReady: dictationReady, facts: dictationFacts)
    }

    /// The Cohere row: ready, installing or failed as the engine says; before an install
    /// the size to download, or that TypeWhisper's copy is used. `facts` is `nil` while the
    /// step is being prepared.
    internal static func dictationRowState(
        engine: DictationController.EngineState,
        isReady: Bool,
        facts: DictationRowFacts?
    ) -> ModelRowState {
        if isReady {
            return .ready
        }
        switch engine {
        case let .installing(fraction):
            return .downloading(.determinate(fraction: fraction))
        case let .failed(message):
            return .failed(message: message)
        case .notInstalled, .installed, .loading, .ready:
            break
        }
        guard let facts else { return .checking }
        if facts.plan.downloadBytes > facts.availableBytes {
            return .insufficientDisk
        }
        if facts.plan.copiesModelFromTypeWhisper {
            return .idle(sizeCaption: "Copied from TypeWhisper")
        }
        return .idle(sizeCaption: formatBytes(facts.plan.downloadBytes))
    }
}

/// What the Cohere row shows before an install.
struct DictationRowFacts: Equatable {
    var plan: DictationInstallPlan
    /// Free disk space when the model step was prepared.
    var availableBytes: Int64
}
