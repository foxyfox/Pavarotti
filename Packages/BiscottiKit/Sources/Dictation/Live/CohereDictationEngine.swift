import CohereTranscribe
import Foundation
import Synchronization

/// Dictation on top of the local Cohere Transcribe server. Keeps one model loaded and
/// switches when the selected model changes. With an idle limit set, the server stops
/// after the model sat unused that long and starts again with the next request.
public actor CohereDictationEngine: DictationTranscribing {
    /// The engine dictation, files and meetings share, so only one server and one model
    /// are ever loaded.
    public static let shared = CohereDictationEngine()

    private let installer: CohereInstaller
    private var transcriber: CohereTranscriber?
    private var loadedModelID: String?
    /// Whether a meeting is being transcribed and needs word times, see ``setWordTimes(_:)``.
    private var wordTimes = false
    /// How long the model may sit unused before the server stops; `nil` keeps it loaded.
    private var idleLimit: Duration?
    /// Requests and warm-ups running right now; the model is never unloaded under them.
    private var activeUses = 0
    private var idleTask: Task<Void, Never>?

    public init(installer: CohereInstaller = CohereInstaller()) {
        self.installer = installer
    }

    /// Whether the word aligner for meeting transcripts is installed.
    public nonisolated var isWordAlignerInstalled: Bool {
        installer.isInstalled(CohereAssetCatalog.wordAligner)
    }

    /// Whether meetings with this model get their word times from the aligner. Parakeet
    /// times the words itself; an unknown model is treated like Cohere.
    public nonisolated func usesWordAligner(modelID: String) -> Bool {
        CohereModel.model(id: modelID)?.backend.usesWordAligner ?? true
    }

    /// Bytes the word aligner still needs to download, 0 once installed.
    public nonisolated var wordAlignerDownloadBytes: Int64 {
        isWordAlignerInstalled ? 0 : CohereAssetCatalog.wordAligner.size
    }

    /// Installs the word aligner. The server takes it up with the next request.
    public func installWordAligner(progress: @escaping @Sendable (Double) -> Void) async throws {
        let throttle = ProgressThrottle()
        try await installer.install(assets: [CohereAssetCatalog.wordAligner]) { update in
            if throttle.shouldReport(update.fraction) {
                progress(update.fraction)
            }
        }
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
        beginUse()
        defer { endUse() }
        try await loadedTranscriber(for: modelID).warmUp()
    }

    public func transcribe(
        samples: [Float],
        sampleRate: Int,
        language: TranscriptionLanguage,
        modelID: String
    ) async throws -> String {
        beginUse()
        defer { endUse() }
        return try await loadedTranscriber(for: modelID).transcribe(
            samples: samples,
            sampleRate: sampleRate,
            language: language
        ).text
    }

    public func transcribeTimed(
        samples: [Float],
        sampleRate: Int,
        language: TranscriptionLanguage,
        modelID: String
    ) async throws -> TimedTranscription {
        beginUse()
        defer { endUse() }
        let result = try await loadedTranscriber(for: modelID).transcribe(
            samples: samples,
            sampleRate: sampleRate,
            language: language
        )
        var passages = result.segments.map { segment in
            TimedText(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                words: segment.words.map { TimedWord(text: $0.text, start: $0.start, end: $0.end) }
            )
        }
        if passages.isEmpty, !result.text.isEmpty {
            // The server left out the segments; the text then covers the whole audio.
            passages = [TimedText(start: 0, end: Double(samples.count) / Double(sampleRate), text: result.text)]
        }
        return TimedTranscription(language: result.language, passages: passages)
    }

    public func shutdown() async {
        idleTask?.cancel()
        idleTask = nil
        let running = transcriber
        transcriber = nil
        loadedModelID = nil
        await running?.shutdown()
    }

    public func setIdleUnload(after limit: Duration?) async {
        idleLimit = limit
        scheduleIdleUnload()
    }

    /// Meetings need exact word times, which Cohere gets from the aligner; dictation and
    /// files do not. While on, the server runs with the aligner and is never unloaded.
    public func setWordTimes(_ wanted: Bool) async {
        wordTimes = wanted
        await transcriber?.setWordTimes(wanted)
        scheduleIdleUnload()
    }

    /// Marks a use of the model, so an idle unload never cuts into it.
    private func beginUse() {
        activeUses += 1
        idleTask?.cancel()
        idleTask = nil
    }

    /// Ends a use and starts the idle countdown again once nothing uses the model.
    private func endUse() {
        activeUses -= 1
        scheduleIdleUnload()
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = nil
        guard let idleLimit, transcriber != nil, activeUses == 0 else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: idleLimit)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    /// Stops the server when nothing uses it. The transcriber stays, so the next request
    /// starts the server again.
    private func unloadIfIdle() async {
        guard activeUses == 0, !wordTimes, let transcriber else { return }
        await transcriber.shutdown()
    }

    private func loadedTranscriber(for modelID: String) async throws -> CohereTranscriber {
        if let transcriber, loadedModelID == modelID {
            return transcriber
        }
        let previous = transcriber
        let created = try CohereTranscriber(model: Self.model(modelID), installer: installer, wordTimes: wordTimes)
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
