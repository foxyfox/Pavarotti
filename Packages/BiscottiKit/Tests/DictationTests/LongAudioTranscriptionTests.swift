import CohereTranscribe
import Foundation
import Testing
@testable import Dictation

@Suite("Long audio transcription")
struct LongAudioTranscriptionTests {
    private let sampleRate = DictationAudio.sampleRate

    @Test("Pieces are cut at a quiet moment and their passages and words moved to the recording's time")
    func piecesKeepTheRecordingsTime() async throws {
        let engine = FakeEngine()
        engine.state.withLock {
            $0.timed = [
                TimedTranscription(language: "de", passages: [
                    TimedText(start: 1, end: 2, text: "Hallo.", words: [TimedWord(text: "Hallo.", start: 1, end: 1.5)])
                ]),
                TimedTranscription(language: "en", passages: [
                    TimedText(start: 0.5, end: 3, text: "Hi there.", words: [
                        TimedWord(text: "Hi", start: 0.5, end: 0.7),
                        TimedWord(text: "there.", start: 0.9, end: 1.2)
                    ])
                ])
            ]
        }
        // Speech with one quiet second at 110 s, where the first piece ends.
        let samples = FakeAudioSource.speech(seconds: 110) + FakeAudioSource.silence(seconds: 1)
            + FakeAudioSource.speech(seconds: 39)

        let result = try await engine.transcribeLong(
            samples: samples,
            sampleRate: sampleRate,
            language: .automatic,
            modelID: "model"
        )

        let requests = engine.state.withLock { $0.requests }
        try #require(requests.count == 2)
        #expect(requests.allSatisfy { $0.language == .automatic && $0.modelID == "model" })
        #expect(requests.map(\.sampleCount).reduce(0, +) == samples.count)

        let cut = Double(requests[0].sampleCount) / Double(sampleRate)
        #expect(abs(cut - 110.05) < 0.001)
        try #require(result.passages.map(\.text) == ["Hallo.", "Hi there."])
        #expect(result.passages[0].start == 1)
        #expect(abs(result.passages[1].start - (cut + 0.5)) < 1e-9)
        #expect(abs(result.passages[1].words[1].start - (cut + 0.9)) < 1e-9)
        #expect(abs(result.passages[1].words[1].end - (cut + 1.2)) < 1e-9)
        // English was heard for 2.5 s, German for 1 s.
        #expect(result.language == "en")
    }

    @Test("Digital silence is not sent to the server")
    func skipsSilence() async throws {
        let engine = FakeEngine()

        let result = try await engine.transcribeLong(
            samples: FakeAudioSource.silence(seconds: 5),
            sampleRate: sampleRate,
            language: .german,
            modelID: "model"
        )

        #expect(engine.state.withLock { $0.requests }.isEmpty)
        #expect(result == TimedTranscription(language: nil, passages: []))
    }

    @Test("Shifting a passage moves its words too")
    func shiftsWords() {
        let passage = TimedText(start: 1, end: 2, text: "Ja", words: [TimedWord(text: "Ja", start: 1.25, end: 1.5)])
        let shifted = passage.shifted(by: 10)
        #expect(shifted.start == 11)
        #expect(shifted.end == 12)
        #expect(shifted.words == [TimedWord(text: "Ja", start: 11.25, end: 11.5)])
    }
}
