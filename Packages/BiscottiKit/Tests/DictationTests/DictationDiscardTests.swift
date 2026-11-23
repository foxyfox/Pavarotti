import Foundation
import Testing
@testable import Dictation

@Suite("Discarding a dictation with Escape")
@MainActor
struct DictationDiscardTests {
    @Test("discarding while listening drops the audio and pastes nothing")
    func discardWhileListening() async {
        let harness = DictationHarness { $0.ducksAudio = true }
        defer { harness.tearDown() }
        let controller = harness.controller

        #expect(await harness.startListening())
        #expect(controller.isDictating)
        controller.discard()

        #expect(controller.phase == .idle)
        #expect(!controller.isDictating)
        #expect(harness.audio.cancelCount == 1)
        #expect(harness.ducker.restoreCount == 1)
        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.sounds.played == [.system("Tink")])
    }

    @Test("discarding while transcribing pastes nothing")
    func discardWhileTranscribing() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        let controller = harness.controller

        #expect(await harness.startListening())
        harness.audio.samples = FakeAudioSource.speech(seconds: 1)
        controller.stop()
        #expect(controller.phase == .transcribing)
        #expect(controller.isDictating)
        controller.discard()
        await controller.waitForWork()

        #expect(controller.phase == .idle)
        #expect(harness.inserter.inserted.isEmpty)
        #expect(controller.lastTranscript == nil)
    }

    @Test("discarding with no dictation running does nothing")
    func discardWhenIdle() {
        let harness = DictationHarness()
        defer { harness.tearDown() }

        #expect(!harness.controller.isDictating)
        harness.controller.discard()

        #expect(harness.controller.phase == .idle)
        #expect(harness.audio.cancelCount == 0)
    }

    @Test("the shortcut starts a new dictation after a discard")
    func shortcutWorksAfterDiscard() {
        let harness = DictationHarness { $0.mode = .toggle }
        defer { harness.tearDown() }
        let controller = harness.controller

        controller.handle(.pressed)
        controller.handle(.released)
        #expect(controller.phase == .listening)
        controller.discard()
        #expect(controller.phase == .idle)

        controller.handle(.pressed)
        #expect(controller.phase == .listening)
    }
}
