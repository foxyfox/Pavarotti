import Foundation
import Testing
@testable import Dictation

/// Hands out fixed audio in pieces of ten seconds.
struct FakeAudioFileReader: AudioFileReading {
    var audio: [Float] = []
    var error: FileTranscriptionError?
    /// Leaves the stream open after the audio, like a slow file.
    var staysOpen = false

    func duration(of _: URL) async throws -> TimeInterval {
        if let error {
            throw error
        }
        return Double(audio.count) / Double(DictationAudio.sampleRate)
    }

    func samples(of _: URL, sampleRate: Int) -> AsyncThrowingStream<[Float], any Error> {
        let audio = audio
        let staysOpen = staysOpen
        return AsyncThrowingStream { continuation in
            for start in stride(from: 0, to: audio.count, by: 10 * sampleRate) {
                continuation.yield(Array(audio[start ..< min(start + 10 * sampleRate, audio.count)]))
            }
            if !staysOpen {
                continuation.finish()
            }
        }
    }
}

@MainActor
@Suite("File transcription")
struct FileTranscriptionSessionTests {
    let file = URL(fileURLWithPath: "/tmp/Interview.m4a")

    private func session(_ harness: DictationHarness, reader: FakeAudioFileReader) -> FileTranscriptionSession {
        FileTranscriptionSession(controller: harness.controller, reader: reader) {
            Date(timeIntervalSince1970: 1_793_116_800)
        }
    }

    private func finished(_ session: FileTranscriptionSession) -> FileTranscript? {
        if case let .finished(transcript) = session.state { transcript } else { nil }
    }

    @Test("A long file is sent in pieces cut at quiet moments, with times from the start of the file")
    func piecesAtQuietMoments() async throws {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.engine.state.withLock { $0.timed = Array(repeating: Self.hallo, count: 3) }
        // Quiet at 110 and 220 seconds, so the pieces end at 110.05 and 220.1 seconds.
        let audio = FakeAudioSource.speech(seconds: 110) + FakeAudioSource.silence(seconds: 1)
            + FakeAudioSource.speech(seconds: 109) + FakeAudioSource.silence(seconds: 1)
            + FakeAudioSource.speech(seconds: 79)
        let session = session(harness, reader: FakeAudioFileReader(audio: audio))

        session.transcribe(file)
        await session.waitForWork()

        let transcript = try #require(finished(session))
        let starts = transcript.passages.map(\.start)
        #expect(starts.count == 3)
        #expect(abs(starts[0] - 1) < 0.001)
        #expect(abs(starts[1] - 111.05) < 0.001)
        #expect(abs(starts[2] - 221.1) < 0.001)
        #expect(harness.engine.state.withLock { $0.requests.map(\.sampleCount) } == [1_760_800, 1_760_800, 1_278_400])
        #expect(transcript.duration == 300)
        #expect(transcript.source == file)
    }

    @Test("Digital silence is skipped without asking the engine")
    func skipsSilence() async throws {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        let audio = FakeAudioSource.silence(seconds: 125) + FakeAudioSource.speech(seconds: 5)
        let session = session(harness, reader: FakeAudioFileReader(audio: audio))

        session.transcribe(file)
        await session.waitForWork()

        let transcript = try #require(finished(session))
        #expect(harness.engine.state.withLock { $0.requests.count } == 1)
        #expect(transcript.passages.map(\.text) == ["Hallo Welt"])
        #expect(try #require(transcript.passages.first?.start) > 100)
    }

    @Test("The dictionary applies to file transcripts as it does to dictation")
    func appliesDictionary() async throws {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        try harness.dictionary.add(original: "welt", replacement: "World")
        let session = session(harness, reader: FakeAudioFileReader(audio: FakeAudioSource.speech(seconds: 3)))

        session.transcribe(file)
        await session.waitForWork()

        #expect(finished(session)?.passages.map(\.text) == ["Hallo World"])
    }

    @Test("The language spoken longest is the transcript's")
    func mainLanguage() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.engine.state.withLock {
            $0.timed = [
                TimedTranscription(language: "de", passages: [TimedText(start: 0, end: 5, text: "Kurz.")]),
                TimedTranscription(language: "en", passages: [TimedText(start: 0, end: 50, text: "Long.")])
            ]
        }
        let session = session(harness, reader: FakeAudioFileReader(audio: FakeAudioSource.speech(seconds: 150)))

        session.transcribe(file)
        await session.waitForWork()

        #expect(finished(session)?.language == "en")
    }

    @Test("A file without speech fails with a message")
    func nothingHeard() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        let session = session(harness, reader: FakeAudioFileReader(audio: FakeAudioSource.silence(seconds: 4)))

        session.transcribe(file)
        await session.waitForWork()

        #expect(session.state == .failed(file: file, message: FileTranscriptionError.nothingHeard("Interview.m4a").localizedDescription))
    }

    @Test("A file Pavarotti cannot read fails with a message")
    func unreadable() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        let reader = FakeAudioFileReader(error: .unreadable("Interview.m4a"))
        let session = session(harness, reader: reader)

        session.transcribe(file)
        await session.waitForWork()

        #expect(session.state == .failed(file: file, message: FileTranscriptionError.unreadable("Interview.m4a").localizedDescription))
    }

    @Test("Without the model the file is not read")
    func modelMissing() {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.engine.state.withLock { $0.isInstalled = false }
        let session = session(harness, reader: FakeAudioFileReader(audio: FakeAudioSource.speech(seconds: 3)))

        session.transcribe(file)

        #expect(!session.isModelInstalled)
        #expect(session.state == .failed(file: file, message: DictationError.modelNotInstalled.localizedDescription))
    }

    @Test("Cancelling goes back to the start and keeps no result")
    func cancel() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        let reader = FakeAudioFileReader(audio: FakeAudioSource.speech(seconds: 3), staysOpen: true)
        let session = session(harness, reader: reader)

        session.transcribe(file)
        #expect(session.isTranscribing)
        session.cancel()
        await session.waitForWork()

        #expect(session.state == .idle)
    }

    @Test("Without dictation the model is unloaded after the file")
    func unloadsWithoutDictation() async {
        let harness = DictationHarness { $0.isEnabled = false }
        defer { harness.tearDown() }
        let session = session(harness, reader: FakeAudioFileReader(audio: FakeAudioSource.speech(seconds: 3)))

        session.transcribe(file)
        await session.waitForWork()

        #expect(finished(session) != nil)
        #expect(harness.engine.state.withLock { $0.shutdownCount } == 1)
    }

    @Test("With dictation on the model stays loaded")
    func keepsModelForDictation() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        let session = session(harness, reader: FakeAudioFileReader(audio: FakeAudioSource.speech(seconds: 3)))

        session.transcribe(file)
        await session.waitForWork()

        #expect(harness.engine.state.withLock { $0.shutdownCount } == 0)
    }

    private static let hallo = TimedTranscription(language: "de", passages: [TimedText(start: 1, end: 2, text: " Hallo ")])
}
