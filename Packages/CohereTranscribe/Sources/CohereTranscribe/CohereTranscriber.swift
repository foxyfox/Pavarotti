import Foundation

/// Local speech-to-text with Cohere Transcribe (or Parakeet) through CrispASR.
///
/// Starts the server on first use and keeps it warm. In automatic mode it detects
/// German or English and transcribes anything else as German; any other language the
/// model knows can be chosen. Parakeet detects the language itself and writes whatever
/// it hears.
public actor CohereTranscriber {
    public let model: CohereModel
    public let installer: CohereInstaller
    private var server: CrispASRServer?
    /// Whether answers should carry exact word times from the aligner, see
    /// ``setWordTimes(_:)``.
    private var wantsWordTimes = false

    public init(
        model: CohereModel = .recommended,
        installer: CohereInstaller = CohereInstaller(),
        wordTimes: Bool = false
    ) {
        self.model = model
        self.installer = installer
        wantsWordTimes = wordTimes
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

    /// Meetings need exact word times from the aligner to match words to speakers;
    /// dictation does not, and the aligner costs about 400 MB and time on every request.
    /// A server started the other way stops here; the next request starts it again.
    public func setWordTimes(_ wanted: Bool) async {
        guard wanted != wantsWordTimes else { return }
        wantsWordTimes = wanted
        if let server, server.configuration.wordAligner != wordAlignerPath {
            self.server = nil
            await server.stop()
        }
    }

    /// Stops the server and frees the model's memory.
    public func shutdown() async {
        // Forgotten before stopping, so a request that comes in meanwhile starts a new
        // server instead of reviving this one.
        let running = server
        server = nil
        await running?.stop()
    }

    // MARK: - Private

    private func transcribe(
        audio: Data,
        filename: String,
        language: TranscriptionLanguage
    ) async throws -> CohereTranscription {
        // A language this model does not know, chosen for another model, falls back to
        // automatic.
        let language = model.supports(language) ? language : .automatic
        let server = try await runningServer()
        let detectsItself = model.backend.detectsLanguage
        let serverDetects = await server.detectsLanguage
        var requested = LanguagePolicy.firstRequest(
            for: language,
            detectionAvailable: detectsItself || serverDetects
        )
        var answer = try await server.transcribe(request(audio: audio, filename: filename, language: requested))
        if !detectsItself,
           let retry = LanguagePolicy.retryLanguage(afterRequesting: requested, detected: answer.language)
        {
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
            language: detectsItself
                ? LanguagePolicy.heardLanguage(requested: requested, detected: answer.language)
                : LanguagePolicy.resolvedLanguage(requested: requested, detected: answer.language),
            segments: segments
        )
    }

    private func request(audio: Data, filename: String, language: String) -> TranscriptionRequest {
        TranscriptionRequest(
            audio: audio,
            filename: filename,
            model: model.id,
            language: language,
            skipsLanguageIdentification: model.backend.detectsLanguage
        )
    }

    private func runningServer() async throws -> CrispASRServer {
        if let server, server.configuration.wordAligner != wordAlignerPath {
            // Word times were switched, or the aligner was installed while the server ran.
            self.server = nil
            await server.stop()
        }
        let running = try server ?? makeServer()
        server = running
        try await running.start()
        return running
    }

    /// The aligner the server should run with: only while word times are wanted, for a
    /// model that takes them from the aligner, and once it is installed.
    private var wordAlignerPath: URL? {
        guard wantsWordTimes, model.backend.usesWordAligner,
              installer.isInstalled(CohereAssetCatalog.wordAligner)
        else {
            return nil
        }
        return installer.root.appending(path: CohereAssetCatalog.wordAligner.relativePath)
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
            backend: model.backend,
            voiceActivityModel: root.appending(path: CohereAssetCatalog.voiceActivityModel.relativePath),
            languageIdentificationModel: model.backend.detectsLanguage
                ? nil
                : root.appending(path: CohereAssetCatalog.languageIdentificationModel.relativePath),
            wordAligner: wordAlignerPath,
            cacheDirectory: root.appending(path: "Cache", directoryHint: .isDirectory)
        )
        return CrispASRServer(configuration: configuration)
    }
}
