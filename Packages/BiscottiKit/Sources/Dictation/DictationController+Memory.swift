import Foundation

extension DictationController {
    /// Tells the engine how long the model may sit unused before it is unloaded.
    func applyModelRetention() {
        let engine = dependencies.engine
        let limit = settings.modelRetention.idleLimit
        Task { await engine.setIdleUnload(after: limit) }
    }

    /// With idle unloading on, the model may have been unloaded during a pause. Loading it
    /// as soon as the user starts speaking means it is ready, or nearly, when they stop.
    /// Does nothing when it is still loaded.
    func warmUpWhileListening() {
        guard settings.modelRetention != .always else { return }
        let engine = dependencies.engine
        let modelID = settings.modelID
        Task { try? await engine.prepare(modelID: modelID) }
    }
}
