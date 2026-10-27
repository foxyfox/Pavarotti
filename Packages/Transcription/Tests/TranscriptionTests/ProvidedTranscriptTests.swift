import Foundation
import SpeakerKit
import Testing
@testable import Transcription

private typealias Word = ProvidedTranscript.Word

/// Words one after another, each starting `step` seconds after the previous one.
private func words(_ text: String, from start: TimeInterval, step: TimeInterval = 0.3) -> [Word] {
    text.split(separator: " ").enumerated().map { index, word in
        let wordStart = start + Double(index) * step
        return Word(text: String(word), start: wordStart, end: wordStart + 0.08)
    }
}

@Suite("Sentence splitting")
struct SentenceSplitterTests {
    private func split(_ text: String) -> [String] {
        SentenceSplitter.sentences(of: words(text, from: 0)).map { $0.map(\.text).joined(separator: " ") }
    }

    @Test("Sentence marks end sentences")
    func marks() {
        #expect(split("Wie geht's? Gut. Wirklich!") == ["Wie geht's?", "Gut.", "Wirklich!"])
        #expect(split("Hallo Welt") == ["Hallo Welt"])
    }

    @Test("Abbreviations, dates and ordinals do not end sentences")
    func falseEnds() {
        #expect(split("Das kostet ca. 10 Euro.") == ["Das kostet ca. 10 Euro."])
        #expect(split("Das ist z.B. gut.") == ["Das ist z.B. gut."])
        #expect(split("Wir treffen uns am 3. Oktober.") == ["Wir treffen uns am 3. Oktober."])
        #expect(split("Das ist im 3. Quartal geplant.") == ["Das ist im 3. Quartal geplant."])
        #expect(split("Es waren 15. Dann gingen wir.") == ["Es waren 15.", "Dann gingen wir."])
    }

    @Test("A dot before a lowercase word does not end the sentence")
    func lowercaseContinuation() {
        #expect(split("Der 28. ist frei. Danke.") == ["Der 28. ist frei.", "Danke."])
    }

    @Test("Closing quotes after the mark still end the sentence")
    func closingQuotes() {
        #expect(SentenceSplitter.endsSentence("gesagt.\u{201C}", before: "Dann"))
        #expect(!SentenceSplitter.endsSentence("gesagt", before: "Dann"))
    }
}

@Suite("Provided transcript")
struct ProvidedTranscriptTests {
    @Test("Each sentence becomes one segment with spaced words")
    func sentencesBecomeSegments() {
        let transcript = ProvidedTranscript(
            methodID: "cohere",
            language: "de",
            segments: [
                .init(start: 0, end: 2, text: "Hallo Laura. Wie geht's?", words: words("Hallo Laura. Wie geht's?", from: 0))
            ]
        )
        let result = transcript.transcriptionResult()
        #expect(result.language == "de")
        #expect(result.segments.map(\.text) == [" Hallo Laura.", " Wie geht's?"])
        #expect(result.segments[0].words?.map(\.word) == [" Hallo", " Laura."])
        #expect(result.segments[1].start == Float(0.6))
    }

    @Test("A word lasts until the next starts, at most a second, at least 80 ms")
    func wordTimes() {
        let sentence = [
            Word(text: "Okay.", start: 1.0, end: 4.0),
            Word(text: "Gut", start: 4.5, end: 4.58),
            Word(text: "so.", start: 4.8, end: 4.8)
        ]
        let tidied = ProvidedTranscript.tidied([sentence])[0]
        let expected = [2.0, 4.8, 4.88]
        #expect(zip(tidied.map(\.end), expected).allSatisfy { abs($0 - $1) < 1e-9 })
    }

    @Test("A segment without timed words spreads its text evenly")
    func estimatedWords() {
        let segment = ProvidedTranscript.Segment(start: 10, end: 12, text: "eins zwei drei vier", words: [])
        #expect(segment.timedWords.map(\.start) == [10, 10.5, 11, 11.5])
        #expect(segment.timedWords.map(\.text) == ["eins", "zwei", "drei", "vier"])
    }

    @Test("Sentences get the speaker turn they overlap most")
    func speakerMatching() {
        let transcript = ProvidedTranscript(
            methodID: "cohere",
            language: "de",
            segments: [
                .init(start: 0, end: 6, text: "", words: words("Wie lange bist du schon da?", from: 0, step: 0.4)
                    + words("Seit dem ersten April.", from: 3.0, step: 0.4))
            ]
        )
        let diarization = DiarizationResult(
            speakerCount: 2,
            totalFrames: 600,
            frameRate: 100,
            segments: [
                SpeakerSegment(speaker: .speakerId(0), startTime: 0, endTime: 2.6, frameRate: 100),
                SpeakerSegment(speaker: .speakerId(1), startTime: 2.9, endTime: 4.8, frameRate: 100)
            ]
        )
        let groups = diarization.addSpeakerInfo(to: [transcript.transcriptionResult()], strategy: .segment)
        let segments = SegmentBuilder.buildSegments(from: groups)
        #expect(segments.map(\.speakerID) == [0, 1])
        #expect(segments.map { $0.text.trimmingCharacters(in: .whitespaces) } == [
            "Wie lange bist du schon da?", "Seit dem ersten April."
        ])
    }

    @Test("Requests without a transcript still decode, with one round-trips")
    func requestCoding() throws {
        let old = Data(#"{"micPath":"/m","systemPath":"/s","customVocabulary":[]}"#.utf8)
        #expect(try JSONDecoder().decode(XPCProcessRequest.self, from: old).transcript == nil)

        let transcript = ProvidedTranscript(
            methodID: "cohere",
            language: "en",
            segments: [.init(start: 0, end: 1, text: "Hi.", words: [Word(text: "Hi.", start: 0, end: 0.2)])]
        )
        let request = XPCProcessRequest(micPath: "/m", systemPath: "/s", customVocabulary: [], transcript: transcript)
        let decoded = try JSONDecoder().decode(XPCProcessRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.transcript == transcript)
    }

    @Test("The XPC adapter sends the transcript and downloads only the speaker model")
    func adapter() async throws {
        let service = MockTranscriberService()
        service.processAudioResult = makeFixtureResult(transcriptionMethodId: "cohere")
        let adapter = XPCEngineAdapter(proxyProvider: { service })
        let transcript = ProvidedTranscript(methodID: "cohere", language: "de", segments: [])

        let result = try await adapter.processAudio(micPath: "/m", systemPath: "/s", transcript: transcript)
        #expect(result.transcriptionMethodId == "cohere")
        #expect(service.lastProcessRequest?.transcript == transcript)

        try await adapter.ensureSpeakerModelsDownloaded { _ in }
        #expect(service.speakerDownloadCallCount == 1)
    }
}
