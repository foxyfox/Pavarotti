import Foundation
import Testing
@testable import Dictation

@Suite("Dictation and the dictionary")
@MainActor
struct DictationLearningTests {
    /// Runs one dictation of "Hallo Welt" through the harness.
    private func dictate(with harness: DictationHarness) async -> Bool {
        guard await harness.startListening() else { return false }
        harness.audio.samples = FakeAudioSource.silence(seconds: 1)
        harness.controller.stop()
        await harness.controller.waitForWork()
        return true
    }

    @Test("the dictionary fixes the text before pasting, then the field is watched")
    func dictionaryBeforePasting() async throws {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        try harness.dictionary.add(original: "welt", replacement: "World")

        #expect(await dictate(with: harness))

        #expect(harness.inserter.inserted == ["Hallo World"])
        #expect(harness.controller.lastTranscript == "Hallo World")
        #expect(harness.dictionary.entries.first?.usageCount == 1)
        #expect(harness.corrections.watched == ["Hallo World"])
    }

    @Test("a fix in the field is learned and shown, undoing it removes it again")
    func learnsAndUnlearns() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        #expect(await dictate(with: harness))

        harness.corrections.report(DetectedCorrection(original: "Welt", replacement: "Welle"))
        #expect(harness.dictionary.entries.map(\.replacement) == ["Welle"])
        #expect(harness.dictionary.entries.first?.source == .learned)
        #expect(harness.controller.notice == "Added to the dictionary: Welt \u{2192} Welle")

        harness.corrections.report(DetectedCorrection(original: "Welle", replacement: "Welt"))
        #expect(harness.dictionary.entries.isEmpty)
        #expect(harness.controller.notice == "Removed from the dictionary: Welt \u{2192} Welle")
    }

    @Test("with learning off, or when the text was only copied, nothing is watched")
    func noWatch() async {
        let quiet = DictationHarness { $0.learnsFromCorrections = false }
        defer { quiet.tearDown() }
        #expect(await dictate(with: quiet))
        #expect(quiet.inserter.inserted == ["Hallo Welt"])
        #expect(quiet.corrections.watched.isEmpty)

        let copied = DictationHarness()
        defer { copied.tearDown() }
        copied.inserter.result = .copiedOnly
        #expect(await dictate(with: copied))
        #expect(copied.corrections.watched.isEmpty)
    }

    @Test("the next dictation finishes the watch, turning learning off stops it")
    func watchLifecycle() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        #expect(await dictate(with: harness))
        #expect(harness.corrections.finishCount == 1)

        #expect(await dictate(with: harness))
        #expect(harness.corrections.finishCount == 2)
        #expect(harness.corrections.watched.count == 2)

        harness.controller.update { $0.learnsFromCorrections = false }
        #expect(harness.corrections.stopCount == 1)
        harness.corrections.report(DetectedCorrection(original: "Welt", replacement: "Welle"))
        #expect(harness.dictionary.entries.isEmpty)
    }
}
