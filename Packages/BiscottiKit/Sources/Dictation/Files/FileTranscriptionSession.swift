import CohereTranscribe
import Foundation
import Observation
import os

/// Transcribes an audio or video file with the dictation model and keeps the result for
/// the file window.
///
/// The file is read and transcribed in pieces of about two minutes, so memory stays
/// small, progress moves, and a dictation in between waits for one piece at most. The
/// personal dictionary applies as it does for dictation.
@MainActor @Observable
public final class FileTranscriptionSession {
    public enum State: Equatable {
        case idle
        /// `progress` runs from 0 to 1.
        case transcribing(file: URL, progress: Double)
        case finished(FileTranscript)
        case failed(file: URL?, message: String)
    }

    public private(set) var state = State.idle

    private let controller: DictationController
    private let reader: any AudioFileReading
    private let now: @MainActor () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var run = 0

    private static let logger = Logger(subsystem: "de.foxagon.pavarotti", category: "FileTranscription")

    public init(
        controller: DictationController,
        reader: any AudioFileReading = AssetAudioReader(),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.controller = controller
        self.reader = reader
        self.now = now
    }

    public var isTranscribing: Bool {
        if case .transcribing = state { true } else { false }
    }

    /// Whether the dictation model, which also transcribes files, is installed.
    public var isModelInstalled: Bool {
        controller.dependencies.engine.isInstalled(modelID: controller.settings.modelID)
    }

    /// Starts transcribing `url`. A running transcription is cancelled first.
    public func transcribe(_ url: URL) {
        cancel()
        run += 1
        let current = run
        let settings = controller.settings
        guard controller.dependencies.engine.isInstalled(modelID: settings.modelID) else {
            state = .failed(file: url, message: DictationError.modelNotInstalled.localizedDescription)
            return
        }
        state = .transcribing(file: url, progress: 0)
        task = Task { [weak self] in
            await self?.work(url, settings: settings, run: current)
        }
    }

    /// Stops a running transcription and goes back to the start.
    public func cancel() {
        task?.cancel()
        if isTranscribing {
            state = .idle
        }
    }

    /// Forgets the result, for the next file.
    public func reset() {
        cancel()
        state = .idle
    }

    /// Waits for a running transcription. For tests.
    func waitForWork() async {
        await task?.value
    }

    // MARK: - Work

    private func work(_ url: URL, settings: DictationSettings, run current: Int) async {
        let outcome: State?
        do {
            outcome = try await State.finished(transcript(of: url, settings: settings, run: current))
        } catch is CancellationError {
            outcome = nil
        } catch {
            let message = error.localizedDescription
            Self.logger.error("File transcription failed: \(message, privacy: .public)")
            outcome = .failed(file: url, message: message)
        }
        // Without dictation nothing else needs the model, so it gives its memory back.
        if current == run, !controller.settings.isEnabled {
            await controller.dependencies.engine.shutdown()
        }
        guard let outcome, current == run, !Task.isCancelled else { return }
        state = outcome
    }

    private func transcript(of url: URL, settings: DictationSettings, run current: Int) async throws -> FileTranscript {
        let sampleRate = DictationAudio.sampleRate
        let duration = try await reader.duration(of: url)
        let expectedSamples = max(1, duration * Double(sampleRate))
        var chunker = AudioChunker(sampleRate: sampleRate)
        var passages: [TimedText] = []
        var languages = LanguageTally()
        var readSamples = 0

        func add(_ chunk: AudioChunker.Chunk) async throws {
            let result = try await transcribe(chunk, settings: settings)
            passages += result.passages
            languages.add(result)
            readSamples = chunk.offset + chunk.samples.count
            report(Double(readSamples) / expectedSamples, file: url, run: current)
        }

        for try await piece in reader.samples(of: url, sampleRate: sampleRate) {
            for chunk in chunker.append(piece) {
                try await add(chunk)
            }
        }
        if let rest = chunker.finish() {
            try await add(rest)
        }
        try Task.checkCancellation()
        guard !passages.isEmpty else { throw FileTranscriptionError.nothingHeard(url.lastPathComponent) }
        return FileTranscript(
            source: url,
            duration: max(duration, Double(readSamples) / Double(sampleRate)),
            language: languages.mainLanguage,
            passages: passages,
            createdAt: now()
        )
    }

    /// The passages of one piece, in seconds from the start of the file, with the
    /// dictionary applied. Digital silence is skipped without asking the server.
    private func transcribe(_ chunk: AudioChunker.Chunk, settings: DictationSettings) async throws -> TimedTranscription {
        let result = try await controller.dependencies.engine.transcribe(
            chunk,
            sampleRate: DictationAudio.sampleRate,
            language: settings.language,
            modelID: settings.modelID
        )
        let entries = controller.dependencies.dictionary.entries
        let passages = result.passages.compactMap { passage -> TimedText? in
            let heard = passage.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty else { return nil }
            let text = DictionaryReplacer.apply(entries, to: heard).text
            return TimedText(start: passage.start, end: passage.end, text: text)
        }
        return TimedTranscription(language: result.language, passages: passages)
    }

    private func report(_ progress: Double, file: URL, run current: Int) {
        guard current == run, isTranscribing else { return }
        state = .transcribing(file: file, progress: min(1, max(0, progress)))
    }
}
