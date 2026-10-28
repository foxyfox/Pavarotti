import Dictation
import Foundation
import Testing
import Transcription
@testable import AppCore

@Suite("Cohere meeting transcription")
struct CohereMeetingTranscriberTests {
    @Test("What Cohere heard becomes the worker's transcript, words and all")
    func transcriptFromCohere() {
        let heard = TimedTranscription(language: "en", passages: [
            TimedText(start: 3, end: 4.5, text: "Hello there.", words: [
                TimedWord(text: "Hello", start: 3, end: 3.4),
                TimedWord(text: "there.", start: 3.5, end: 4.5)
            ])
        ])

        let transcript = ProvidedTranscript(heard, modelID: "cohere-transcribe-03-2026-q5_0")

        #expect(transcript == ProvidedTranscript(
            methodID: "cohere-transcribe-03-2026-q5_0",
            language: "en",
            segments: [
                .init(start: 3, end: 4.5, text: "Hello there.", words: [
                    .init(text: "Hello", start: 3, end: 3.4),
                    .init(text: "there.", start: 3.5, end: 4.5)
                ])
            ]
        ))
    }

    @Test("Without a detected language the transcript is German")
    func germanByDefault() {
        let transcript = ProvidedTranscript(TimedTranscription(language: nil, passages: []), modelID: "m")
        #expect(transcript.language == "de")
        #expect(transcript.segments.isEmpty)
    }

    @Test("Only Cohere models take meeting word times from the aligner")
    func alignerOnlyForCohere() {
        let engine = CohereDictationEngine()
        #expect(engine.usesWordAligner(modelID: "cohere-transcribe-03-2026-q5_0"))
        #expect(!engine.usesWordAligner(modelID: "parakeet-tdt-0.6b-v3-q4_k"))
        #expect(engine.usesWordAligner(modelID: "unknown"))
    }

    @Test("The personal dictionary corrects the meeting's text and words")
    func dictionaryCorrections() {
        let words = [
            TranscriptWord(word: "Pava", startTime: 0, endTime: 0.4, probability: 1, speakerID: 0),
            TranscriptWord(word: "Rotti", startTime: 0.4, endTime: 0.8, probability: 1, speakerID: 0),
            TranscriptWord(word: "nutzt", startTime: 0.9, endTime: 1.2, probability: 1, speakerID: 0),
            TranscriptWord(word: "Koher.", startTime: 1.3, endTime: 1.8, probability: 1, speakerID: 0)
        ]
        let segment = TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0", startTime: 0, endTime: 1.8,
            text: "Pava Rotti nutzt Koher.", confidence: 1, noSpeechProbability: 0, words: words
        )
        let result = TranscriptResult(
            transcriptionMethodId: "m", language: "de", speakerCount: 1,
            segments: [segment], speakerSpeechDurations: [0: 1.8], processingDuration: 1
        )
        let entries = [
            DictionaryEntry(original: "Pava Rotti", replacement: "Pavarotti"),
            DictionaryEntry(original: "Koher", replacement: "Cohere"),
            DictionaryEntry(original: "nutzt", replacement: "braucht", isEnabled: false)
        ]

        let corrected = result.correcting(with: DictionaryReplacer.Rules(entries))

        let first = corrected.segments[0]
        #expect(first.text == "Pavarotti nutzt Cohere.")
        #expect(first.words?.map(\.word) == ["Pava", "Rotti", "nutzt", "Cohere."])
        #expect(first.id == segment.id)
        #expect(corrected.id == result.id)
        #expect(corrected.speakerSpeechDurations == [0: 1.8])
        #expect(result.correcting(with: DictionaryReplacer.Rules([])) == result)
    }

    @Test("A missing Cohere model says where to install it")
    func missingModelMessage() {
        let message = MeetingTranscriptionError.speechModelNotInstalled.localizedDescription
        #expect(message.contains("Settings \u{2192} Dictation"))
    }
}
