/// The testable seam for transcription workers.
///
/// Both the in-process engine and the future XPC-hosted worker implement this
/// protocol. All inputs are transport-friendly (paths/strings) and the output
/// is the Codable `TranscriptResult`, so it can cross a process boundary as JSON.
public protocol TranscriptionEngine: Sendable {
    /// Download models if not already cached.
    ///
    /// The `status` callback receives a human-readable message for each download
    /// stage (e.g. "Downloading speech-to-text model"). There is no numeric
    /// percentage: the underlying SDK only exposes file-count-weighted progress,
    /// which is misleading for a repo with one multi-GB file among small ones.
    ///
    /// Throws `TranscriptionError.insufficientDisk` if there is not enough space,
    /// or `TranscriptionError.downloadFailed` on network/IO errors.
    func ensureModelsDownloaded(
        status: @escaping @Sendable (String) -> Void
    ) async throws

    /// Process audio files and return a diarized transcript.
    ///
    /// Both `micPath` and `systemPath` are required — the engine merges them
    /// to mono 16 kHz in memory before running STT + diarization. The engine
    /// uses ``TranscriptionMethod/current`` internally; the result carries
    /// the method id in ``TranscriptResult/transcriptionMethodId``.
    ///
    /// - Throws: `TranscriptionError.invalidInput` if audio files are
    ///   empty/unreadable.
    func processAudio(
        micPath: String,
        systemPath: String,
        customVocabulary: [String]
    ) async throws -> TranscriptResult

    /// Explicitly unload all models from memory. The engine remains usable;
    /// models will be re-loaded on the next call.
    func unloadModels() async

    /// Returns `true` when the transcription models are already present on
    /// disk and do NOT need to be downloaded.
    ///
    /// This is a **read-only** probe -- it must not download, load, or
    /// otherwise mutate model state. It exists so callers (e.g. the
    /// onboarding screen) can check readiness without triggering a
    /// multi-GB download.
    func modelsPresent() async -> Bool

    /// The current model lifecycle status.
    func status() async -> ModelStatus

    /// Pavarotti: diarizes the merged audio and gives each sentence of a transcript made
    /// elsewhere (Cohere Transcribe in the app) a speaker. WhisperKit is never loaded.
    func processAudio(
        micPath: String,
        systemPath: String,
        transcript: ProvidedTranscript
    ) async throws -> TranscriptResult

    /// Pavarotti: downloads only the speaker model, which is all
    /// ``processAudio(micPath:systemPath:transcript:)`` needs.
    func ensureSpeakerModelsDownloaded(
        status: @escaping @Sendable (String) -> Void
    ) async throws

    /// Pavarotti: whether the speaker model is on disk. Read-only like ``modelsPresent()``.
    func speakerModelsPresent() async -> Bool
}

public extension TranscriptionEngine {
    func processAudio(
        micPath _: String,
        systemPath _: String,
        transcript _: ProvidedTranscript
    ) async throws -> TranscriptResult {
        throw TranscriptionError.transcriptionFailed("This engine cannot use a transcript made elsewhere.")
    }

    func ensureSpeakerModelsDownloaded(
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        try await ensureModelsDownloaded(status: status)
    }

    func speakerModelsPresent() async -> Bool {
        await modelsPresent()
    }
}
