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

    @Test("A missing Cohere model says where to install it")
    func missingModelMessage() {
        let message = MeetingTranscriptionError.speechModelNotInstalled.localizedDescription
        #expect(message.contains("Settings \u{2192} Dictation"))
    }
}
