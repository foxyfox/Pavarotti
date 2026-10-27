import CohereTranscribe

// Pavarotti: the Cohere model in the setup and in Settings.

public extension DictationController {
    /// What installing the selected model still takes.
    var installPlan: DictationInstallPlan {
        dependencies.engine.installPlan(modelID: settings.modelID)
    }

    /// Before the first install, picks a model TypeWhisper already downloaded, so the setup
    /// copies it instead of downloading. The recommended model wins when TypeWhisper has
    /// several. An installed model or one TypeWhisper has is kept.
    func preferTypeWhisperModel() {
        guard !isModelInstalled, !installPlan.copiesModelFromTypeWhisper else { return }
        let candidates = [CohereModel.recommended] + CohereModel.all
        let engine = dependencies.engine
        guard let found = candidates.first(where: { engine.installPlan(modelID: $0.id).copiesModelFromTypeWhisper }) else {
            return
        }
        update { $0.modelID = found.id }
    }
}
