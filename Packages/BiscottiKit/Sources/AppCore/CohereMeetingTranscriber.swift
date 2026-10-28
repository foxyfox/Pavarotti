import Dictation
import Foundation
import Transcription
import TranscriptionService

/// Pavarotti: transcribes meetings with Cohere Transcribe (or the small Parakeet model)
/// instead of WhisperKit.
///
/// The speech goes through the same local server as dictation, with word times from the
/// aligner (Parakeet times words itself), so only one transcription model is ever loaded. The transcription
/// worker then only finds the speakers (SpeakerKit) and gives each sentence the speaker
/// it overlaps most; voice profiles and participant matching work on that as before.
struct CohereMeetingTranscriber: Transcribing {
    let transcriber: Transcriber
    let speech: CohereDictationEngine
    /// The dictation settings, which choose the model and language for meetings too.
    let settings: @Sendable () -> DictationSettings
    /// The personal dictionary's entries, which correct meetings as they correct dictation.
    let dictionary: @Sendable () -> [DictionaryEntry]

    init(
        transcriber: Transcriber,
        speech: CohereDictationEngine = .shared,
        settings: @escaping @Sendable () -> DictationSettings = { DictationSettingsStore.load() },
        dictionary: @escaping @Sendable () -> [DictionaryEntry] = { PersonalDictionary.storedEntries() }
    ) {
        self.transcriber = transcriber
        self.speech = speech
        self.settings = settings
        self.dictionary = dictionary
    }

    /// Whether the chosen model gets its word times from the aligner. Parakeet times the
    /// words itself.
    private var needsWordAligner: Bool {
        speech.usesWordAligner(modelID: settings().modelID)
    }

    /// The speaker model and, for Cohere, the word aligner. The speech model itself is
    /// installed in Settings → Dictation.
    func ensureModelsDownloaded(status: (@Sendable (String) -> Void)?) async throws {
        try await transcriber.ensureSpeakerModelsDownloaded(status: status)
        guard needsWordAligner, !speech.isWordAlignerInstalled else { return }
        status?("Downloading word timing model")
        do {
            try await speech.installWordAligner { _ in }
        } catch {
            throw TranscriptionError.downloadFailed(error.localizedDescription)
        }
    }

    /// Cohere takes no vocabulary prompt, so the personal dictionary corrects the finished
    /// transcript instead, as it does for dictation.
    func processAudio(mic: URL, system: URL, customVocabulary _: [String]) async throws -> TranscriptResult {
        let chosen = settings()
        guard speech.isInstalled(modelID: chosen.modelID) else {
            throw MeetingTranscriptionError.speechModelNotInstalled
        }
        let samples = try AudioMerger.loadMerged(micPath: mic.path, systemPath: system.path)
        // Sentences are matched to speakers by their words' times. `shutdown()` turns this
        // off again once the batch is done.
        await speech.setWordTimes(true)
        let heard = try await speech.transcribeLong(
            samples: samples,
            sampleRate: Int(AudioMerger.sampleRate),
            language: chosen.language,
            modelID: chosen.modelID
        )
        let transcript = ProvidedTranscript(heard, modelID: chosen.modelID)
        let result = try await transcriber.processAudio(mic: mic, system: system, transcript: transcript)
        return result.correcting(with: DictionaryReplacer.Rules(dictionary()))
    }

    func modelsPresent() async -> Bool {
        let speakers = await transcriber.speakerModelsPresent()
        return speakers && (!needsWordAligner || speech.isWordAlignerInstalled)
    }

    func shutdown() async {
        await transcriber.shutdown()
        // Dictation needs no word times, so the aligner leaves memory again.
        await speech.setWordTimes(false)
        let chosen = settings()
        if chosen.isEnabled {
            // Ready for the next dictation, now without the aligner.
            try? await speech.prepare(modelID: chosen.modelID)
        } else {
            // Without dictation nothing else needs the speech server, so it gives its memory back.
            await speech.shutdown()
        }
    }
}

enum MeetingTranscriptionError: Error, LocalizedError {
    case speechModelNotInstalled

    var errorDescription: String? {
        switch self {
        case .speechModelNotInstalled:
            String(localized: "Meetings are transcribed with the dictation model. Install it in Settings \u{2192} Dictation first.")
        }
    }
}

extension ProvidedTranscript {
    /// What Cohere heard, for the transcription worker. The language falls back to German,
    /// as Cohere's own detection does.
    init(_ heard: TimedTranscription, modelID: String) {
        self.init(
            methodID: modelID,
            language: heard.language ?? "de",
            segments: heard.passages.map { passage in
                Segment(
                    start: passage.start,
                    end: passage.end,
                    text: passage.text,
                    words: passage.words.map { Word(text: $0.text, start: $0.start, end: $0.end) }
                )
            }
        )
    }
}

extension TranscriptResult {
    /// The transcript with the dictionary's corrections in every segment's text and in its
    /// words, one word at a time (an original of several words changes only the text).
    func correcting(with rules: DictionaryReplacer.Rules) -> TranscriptResult {
        guard !rules.isEmpty else { return self }
        let corrected = segments.map { segment in
            TranscriptSegment(
                id: segment.id,
                speakerID: segment.speakerID,
                speakerLabel: segment.speakerLabel,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: DictionaryReplacer.apply(rules, to: segment.text).text,
                confidence: segment.confidence,
                noSpeechProbability: segment.noSpeechProbability,
                words: segment.words?.map { word in
                    TranscriptWord(
                        word: DictionaryReplacer.apply(rules, to: word.word).text,
                        startTime: word.startTime,
                        endTime: word.endTime,
                        probability: word.probability,
                        speakerID: word.speakerID
                    )
                }
            )
        }
        return TranscriptResult(
            id: id,
            createdAt: createdAt,
            transcriptionMethodId: transcriptionMethodId,
            language: language,
            speakerCount: speakerCount,
            segments: corrected,
            embeddingSets: embeddingSets,
            speakerSpeechDurations: speakerSpeechDurations,
            processingDuration: processingDuration
        )
    }
}
