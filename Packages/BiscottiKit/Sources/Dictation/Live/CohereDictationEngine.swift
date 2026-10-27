import CohereTranscribe
import Foundation
import Synchronization

/// Dictation on top of the local Cohere Transcribe server. Keeps one model loaded and
/// switches when the selected model changes.
public actor CohereDictationEngine: DictationTranscribing {
    private let installer: CohereInstaller
    private var transcriber: CohereTranscriber?
    private var loadedModelID: String?

    public init(installer: CohereInstaller = CohereInstaller()) {
        self.installer = installer
    }

    public nonisolated func isInstalled(modelID: String) -> Bool {
        guard let model = CohereModel.model(id: modelID) else { return false }
        return installer.missingAssets(for: model).isEmpty
    }

    public nonisolated func installPlan(modelID: String) -> DictationInstallPlan {
        guard let model = CohereModel.model(id: modelID) else {
            return DictationInstallPlan(downloadBytes: 0, copiesModelFromTypeWhisper: false)
        }
        return DictationInstallPlan(
            downloadBytes: installer.downloadSize(for: model),
            copiesModelFromTypeWhisper: !installer.isInstalled(model.asset) && installer.hasSeedCopy(of: model.asset)
        )
    }

    public func install(modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let model = try Self.model(modelID)
        let throttle = ProgressThrottle()
        try await installer.install(model: model) { update in
            if throttle.shouldReport(update.fraction) {
                progress(update.fraction)
            }
        }
    }

    public func prepare(modelID: String) async throws {
        try await loadedTranscriber(for: modelID).warmUp()
    }

    public func transcribe(
        samples: [Float],
        sampleRate: Int,
        language: TranscriptionLanguage,
        modelID: String
    ) async throws -> String {
        let result = try await loadedTranscriber(for: modelID).transcribe(
            samples: samples,
            sampleRate: sampleRate,
            language: language
        )
        return result.text
    }

    public func shutdown() async {
        let running = transcriber
        transcriber = nil
        loadedModelID = nil
        await running?.shutdown()
    }

    private func loadedTranscriber(for modelID: String) async throws -> CohereTranscriber {
        if let transcriber, loadedModelID == modelID {
            return transcriber
        }
        let previous = transcriber
        let created = try CohereTranscriber(model: Self.model(modelID), installer: installer)
        transcriber = created
        loadedModelID = modelID
        await previous?.shutdown()
        return created
    }

    private static func model(_ id: String) throws -> CohereModel {
        guard let model = CohereModel.model(id: id) else { throw DictationError.unknownModel(id) }
        return model
    }
}

/// Lets progress through about every half percent, so a 2 GB download does not flood
/// the main actor with updates.
final class ProgressThrottle: Sendable {
    private let lastReported = Mutex<Double>(-1)

    func shouldReport(_ fraction: Double) -> Bool {
        lastReported.withLock { last in
            guard fraction >= 1 || fraction - last >= 0.005 else { return false }
            last = fraction
            return true
        }
    }
}
