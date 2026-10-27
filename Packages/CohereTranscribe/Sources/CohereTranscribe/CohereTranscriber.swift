import Foundation

/// Local speech-to-text with Cohere Transcribe through CrispASR.
///
/// Starts the server on first use and keeps it warm. In automatic mode it detects
/// German or English and transcribes anything else as German.
public actor CohereTranscriber {
    public let model: CohereModel
    public let installer: CohereInstaller
    private var server: CrispASRServer?

    public init(model: CohereModel = .recommended, installer: CohereInstaller = CohereInstaller()) {
        self.model = model
        self.installer = installer
    }

    /// Whether the runtime and the model are on disk.
    public nonisolated var isInstalled: Bool {
        installer.missingAssets(for: model).isEmpty
    }

    /// Starts the server ahead of the first request, so that request is fast too.
    public func warmUp() async throws {
        _ = try await runningServer()
    }

    /// Transcribes an audio file (WAV, MP3, M4A, FLAC or OGG).
    public func transcribe(
        fileURL: URL,
        language: TranscriptionLanguage = .automatic
    ) async throws -> CohereTranscription {
        let audio = try Data(contentsOf: fileURL)
        return try await transcribe(audio: audio, filename: fileURL.lastPathComponent, language: language)
    }

    /// Transcribes mono float samples, for example a dictation buffer.
    public func transcribe(
        samples: [Float],
        sampleRate: Int,
        language: TranscriptionLanguage = .automatic
    ) async throws -> CohereTranscription {
        let audio = WAVEncoder.encode(samples: samples, sampleRate: sampleRate)
        return try await transcribe(audio: audio, filename: "dictation.wav", language: language)
    }

    /// Stops the server and frees the model's memory.
    public func shutdown() async {
        await server?.stop()
        server = nil
    }

    // MARK: - Private

    private func transcribe(
        audio: Data,
        filename: String,
        language: TranscriptionLanguage
    ) async throws -> CohereTranscription {
        let server = try await runningServer()
        var requested = await LanguagePolicy.firstRequest(
            for: language,
            detectionAvailable: server.detectsLanguage
        )
        var answer = try await server.transcribe(request(audio: audio, filename: filename, language: requested))
        if let retry = LanguagePolicy.retryLanguage(afterRequesting: requested, detected: answer.language) {
            requested = retry
            answer = try await server.transcribe(request(audio: audio, filename: filename, language: retry))
        }
        let segments = (answer.segments ?? []).map { segment in
            CohereTranscription.Segment(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                words: (segment.words ?? []).map { CohereTranscription.Word(text: $0.word, start: $0.start, end: $0.end) }
            )
        }
        return CohereTranscription(
            text: answer.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: LanguagePolicy.resolvedLanguage(requested: requested, detected: answer.language),
            segments: segments
        )
    }

    private func request(audio: Data, filename: String, language: String) -> TranscriptionRequest {
        TranscriptionRequest(audio: audio, filename: filename, model: model.id, language: language)
    }

    private func runningServer() async throws -> CrispASRServer {
        if let server, server.configuration.wordAligner == nil, installer.isInstalled(CohereAssetCatalog.wordAligner) {
            // The aligner was installed while the server ran; restart so it takes part.
            await server.stop()
            self.server = nil
        }
        let running = try server ?? makeServer()
        server = running
        try await running.start()
        return running
    }

    private func makeServer() throws -> CrispASRServer {
        let missing = installer.missingAssets(for: model)
        guard missing.isEmpty else {
            throw CohereError.notInstalled(missing: missing.map(\.name))
        }
        let root = installer.root
        let configuration = CrispASRServer.Configuration(
            executable: root.appending(path: CohereAssetCatalog.runtimeExecutablePath),
            model: root.appending(path: model.asset.relativePath),
            modelID: model.id,
            voiceActivityModel: root.appending(path: CohereAssetCatalog.voiceActivityModel.relativePath),
            languageIdentificationModel: root.appending(
                path: CohereAssetCatalog.languageIdentificationModel.relativePath
            ),
            wordAligner: installer.isInstalled(CohereAssetCatalog.wordAligner)
                ? root.appending(path: CohereAssetCatalog.wordAligner.relativePath)
                : nil,
            cacheDirectory: root.appending(path: "Cache", directoryHint: .isDirectory)
        )
        return CrispASRServer(configuration: configuration)
    }
}
