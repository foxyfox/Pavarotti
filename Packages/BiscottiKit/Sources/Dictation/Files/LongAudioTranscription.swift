import CohereTranscribe
import Foundation

public extension DictationTranscribing {
    /// Transcribes a long recording that is already in memory, such as a meeting, in
    /// pieces of about two minutes cut at quiet moments, as files are. Passages and words
    /// are in seconds from the start of `samples`; pieces of digital silence are skipped.
    /// The language is the one heard longest.
    func transcribeLong(
        samples: [Float],
        sampleRate: Int,
        language: TranscriptionLanguage,
        modelID: String
    ) async throws -> TimedTranscription {
        var chunker = AudioChunker(sampleRate: sampleRate)
        var tally = LanguageTally()
        var passages: [TimedText] = []

        func add(_ chunk: AudioChunker.Chunk) async throws {
            let result = try await transcribe(chunk, sampleRate: sampleRate, language: language, modelID: modelID)
            tally.add(result)
            passages += result.passages
        }

        // Fed in slices, so only one piece is copied out of `samples` at a time.
        let slice = max(1, sampleRate * 10)
        var position = 0
        while position < samples.count {
            let end = min(samples.count, position + slice)
            for chunk in chunker.append(Array(samples[position ..< end])) {
                try await add(chunk)
            }
            position = end
        }
        if let rest = chunker.finish() {
            try await add(rest)
        }
        return TimedTranscription(language: tally.mainLanguage, passages: passages)
    }
}

extension DictationTranscribing {
    /// The passages of one piece, in seconds from the start of the whole recording.
    /// Digital silence is skipped without asking the server.
    func transcribe(
        _ chunk: AudioChunker.Chunk,
        sampleRate: Int,
        language: TranscriptionLanguage,
        modelID: String
    ) async throws -> TimedTranscription {
        guard !DictationAudio.isSilent(chunk.samples) else {
            return TimedTranscription(language: nil, passages: [])
        }
        let result = try await transcribeTimed(
            samples: chunk.samples,
            sampleRate: sampleRate,
            language: language,
            modelID: modelID
        )
        try Task.checkCancellation()
        let offset = Double(chunk.offset) / Double(sampleRate)
        return TimedTranscription(language: result.language, passages: result.passages.map { $0.shifted(by: offset) })
    }
}

/// Adds up how long each language was heard over the pieces of a recording.
struct LanguageTally {
    private var durations: [String: TimeInterval] = [:]

    mutating func add(_ transcription: TimedTranscription) {
        guard let language = transcription.language else { return }
        durations[language, default: 0] += transcription.passages.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    /// The language heard longest, `nil` when no piece named one.
    var mainLanguage: String? {
        durations.max { $0.value < $1.value }?.key
    }
}
