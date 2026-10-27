import Foundation
import WhisperKit

/// Pavarotti: speech-to-text made outside this package, by Cohere Transcribe in the app.
///
/// Handed to ``TranscriptionEngine/processAudio(micPath:systemPath:transcript:)`` so the
/// engine only runs speaker diarization and never loads WhisperKit. All times are seconds
/// from the start of the merged audio.
public struct ProvidedTranscript: Sendable, Codable, Equatable {
    /// One recognized word.
    public struct Word: Sendable, Codable, Equatable {
        public let text: String
        public let start: TimeInterval
        public let end: TimeInterval

        public init(text: String, start: TimeInterval, end: TimeInterval) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// One stretch of speech as the recognizer returned it. It may hold several
    /// sentences and several speakers.
    public struct Segment: Sendable, Codable, Equatable {
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String
        /// Empty when the recognizer timed no words; they are then spread over the segment.
        public let words: [Word]

        public init(start: TimeInterval, end: TimeInterval, text: String, words: [Word]) {
            self.start = start
            self.end = end
            self.text = text
            self.words = words
        }
    }

    /// Recorded as ``TranscriptResult/transcriptionMethodId``.
    public let methodID: String
    /// ISO 639-1 code of the main language.
    public let language: String
    public let segments: [Segment]

    public init(methodID: String, language: String, segments: [Segment]) {
        self.methodID = methodID
        self.language = language
        self.segments = segments
    }
}

// MARK: - Conversion for SpeakerKit

extension ProvidedTranscript {
    /// Longest a word may last. The aligner stretches a word that ends a sentence over the
    /// following pause; capping it keeps the pause out of the speaker matching.
    static let longestWord: TimeInterval = 1.0
    /// Shortest a word lasts, so every word overlaps the speaker turn it starts in.
    static let shortestWord: TimeInterval = 0.08

    /// The transcript as WhisperKit output with one segment per sentence, so SpeakerKit's
    /// segment strategy gives every sentence the speaker turn it overlaps most. Sentences
    /// read like a dialogue; matching single words would chop overlapping speech apart.
    func transcriptionResult() -> TranscriptionResult {
        let sentences = segments.flatMap { segment in
            SentenceSplitter.sentences(of: segment.timedWords)
        }
        let timed = Self.tidied(sentences)
        let whisperSegments = timed.enumerated().compactMap { index, words -> TranscriptionSegment? in
            guard let first = words.first, let last = words.last else { return nil }
            let timings = words.map {
                WordTiming(word: " " + $0.text, tokens: [], start: Float($0.start), end: Float($0.end), probability: 1)
            }
            return TranscriptionSegment(
                id: index,
                start: Float(first.start),
                end: Float(last.end),
                text: timings.map(\.word).joined(),
                words: timings
            )
        }
        return TranscriptionResult(
            text: whisperSegments.map(\.text).joined(),
            segments: whisperSegments,
            language: language,
            timings: TranscriptionTimings()
        )
    }

    /// Word times as SpeakerKit should see them: each word lasts until the next one starts,
    /// at most ``longestWord`` and at least ``shortestWord``. The aligner's own end is
    /// usually one frame after the start and says little about the spoken end.
    static func tidied(_ sentences: [[Word]]) -> [[Word]] {
        let starts = sentences.flatMap { $0.map(\.start) }
        var index = 0
        return sentences.map { sentence in
            sentence.map { word in
                defer { index += 1 }
                let next = starts.indices.contains(index + 1) ? starts[index + 1] : nil
                let spoken = next.map { min($0, word.start + longestWord) } ?? min(max(word.end, word.start), word.start + longestWord)
                return Word(text: word.text, start: word.start, end: max(spoken, word.start + shortestWord))
            }
        }
    }
}

extension ProvidedTranscript.Segment {
    /// The words, or the text's words spread evenly over the segment when none were timed.
    var timedWords: [ProvidedTranscript.Word] {
        let timed = words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard timed.isEmpty else { return timed }
        let texts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !texts.isEmpty else { return [] }
        let step = max(0, end - start) / Double(texts.count)
        return texts.enumerated().map { index, text in
            let wordStart = start + Double(index) * step
            return ProvidedTranscript.Word(text: text, start: wordStart, end: wordStart + step)
        }
    }
}

// MARK: - Audio

public extension AudioMerger {
    /// Pavarotti: loads both recordings at 16 kHz mono and merges them exactly as the
    /// engine does before diarization, so a transcript made from these samples shares the
    /// engine's timeline.
    static func loadMerged(micPath: String, systemPath: String) throws -> [Float] {
        try AudioLoading.loadAndMerge(micPath: micPath, systemPath: systemPath).samples
    }
}
