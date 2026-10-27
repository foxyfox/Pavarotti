import CohereTranscribe
import Foundation
import Testing
@testable import Dictation

/// Reads real files through AVFoundation.
@Suite("Asset audio reader")
struct AssetAudioReaderTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "pavarotti-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test("A 48 kHz WAV comes out as 16 kHz mono with its level")
    func readsAndResamples() async throws {
        let rate = 48000
        let tone: [Float] = (0 ..< rate).map { 0.5 * sin(2 * Float.pi * 440 * Float($0) / Float(rate)) }
        let file = folder.appending(path: "tone.wav")
        try WAVEncoder.encode(samples: tone, sampleRate: rate).write(to: file)
        let reader = AssetAudioReader()

        let duration = try await reader.duration(of: file)
        var samples: [Float] = []
        for try await piece in reader.samples(of: file, sampleRate: DictationAudio.sampleRate) {
            samples += piece
        }

        #expect(abs(duration - 1) < 0.01)
        #expect(abs(samples.count - DictationAudio.sampleRate) < 200)
        // A sine with amplitude 0.5 has a root mean square of about 0.354.
        #expect(abs(DictationAudio.rms(samples) - 0.354) < 0.03)
    }

    @Test("A file without audio is refused")
    func refusesText() async throws {
        let file = folder.appending(path: "notes.txt")
        try Data("not audio".utf8).write(to: file)

        await #expect(throws: FileTranscriptionError.self) {
            _ = try await AssetAudioReader().duration(of: file)
        }
    }

    @Test("A missing file is refused while reading")
    func refusesMissingFile() async {
        let file = folder.appending(path: "missing.m4a")
        await #expect(throws: FileTranscriptionError.self) {
            for try await _ in AssetAudioReader().samples(of: file, sampleRate: DictationAudio.sampleRate) {}
        }
    }
}
