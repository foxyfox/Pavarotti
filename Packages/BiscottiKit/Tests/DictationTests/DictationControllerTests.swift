import CohereTranscribe
import Foundation
import Testing
@testable import Dictation

@Suite("DictationController")
@MainActor
struct DictationControllerTests {
    // MARK: - The happy path

    @Test("a dictation plays the start cue, ducks, transcribes, pastes and plays the done cue")
    func fullDictation() async {
        let harness = DictationHarness {
            $0.ducksAudio = true
            $0.duckingLevel = 0.25
            $0.language = .german
        }
        defer { harness.tearDown() }
        let controller = harness.controller

        #expect(await harness.startListening())
        #expect(controller.phase == .listening)
        #expect(harness.sounds.played == [.system("Tink")])
        #expect(await eventually { harness.ducker.levels == [0.25] })

        harness.audio.samples = FakeAudioSource.speech(seconds: 1)
        controller.stop()
        #expect(controller.phase == .transcribing)
        #expect(harness.ducker.restoreCount == 1)

        await controller.waitForWork()
        #expect(harness.inserter.inserted == ["Hallo Welt"])
        #expect(harness.inserter.restoredClipboard == [true])
        #expect(harness.sounds.played == [.system("Tink"), .system("Pop")])
        #expect(controller.phase == .idle)
        #expect(controller.lastTranscript == "Hallo Welt")
        #expect(controller.engineState == .ready)
        let requests = harness.engine.state.withLock { $0.requests }
        let expected = FakeEngine.Request(
            sampleCount: 16000,
            sampleRate: 16000,
            language: .german,
            modelID: CohereModel.recommended.id
        )
        #expect(requests == [expected])
    }

    @Test("the start cue plays at full volume, ducking follows once it ended")
    func duckingWaitsForTheStartCue() async {
        let harness = DictationHarness { $0.ducksAudio = true }
        defer { harness.tearDown() }
        harness.sounds.length = 0.4

        #expect(await harness.startListening())
        #expect(harness.ducker.levels.isEmpty)
        #expect(await eventually { harness.ducker.levels == [0.2] })
    }

    @Test("without sounds and ducking nothing plays and the volume stays")
    func quietDictation() async {
        let harness = DictationHarness { $0.playsSounds = false }
        defer { harness.tearDown() }

        #expect(await harness.startListening())
        harness.audio.samples = FakeAudioSource.speech(seconds: 1)
        harness.controller.stop()
        await harness.controller.waitForWork()

        #expect(harness.sounds.played.isEmpty)
        #expect(harness.ducker.levels.isEmpty)
        #expect(harness.inserter.inserted == ["Hallo Welt"])
    }

    // MARK: - Dropped and failed dictations

    @Test("a press shorter than the minimum is dropped")
    func shortPressIsDropped() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }

        #expect(await harness.startListening())
        harness.audio.samples = FakeAudioSource.speech(seconds: 0.1)
        harness.controller.stop()

        #expect(harness.controller.phase == .idle)
        #expect(harness.engine.state.withLock { $0.requests.isEmpty })
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test("without the model, starting fails with the error cue")
    func missingModelFails() {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.engine.state.withLock { $0.isInstalled = false }

        harness.controller.start()

        #expect(harness.controller.phase == .failed(DictationError.modelNotInstalled.localizedDescription))
        #expect(harness.sounds.played == [.system("Basso")])
        #expect(harness.audio.startCount == 0)
    }

    @Test("a microphone that does not start fails with the error cue")
    func microphoneFailure() {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.audio.startError = DictationError.microphoneUnavailable("No input device.")

        harness.controller.start()

        #expect(harness.controller.phase == .failed(DictationError.microphoneUnavailable("No input device.").localizedDescription))
        #expect(harness.sounds.played == [.system("Basso")])
    }

    @Test("a failed transcription shows the error and pastes nothing")
    func transcriptionFailure() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        let error = DictationError.unknownModel("tiny")
        harness.engine.state.withLock { $0.error = error }

        #expect(await harness.startListening())
        harness.audio.samples = FakeAudioSource.speech(seconds: 1)
        harness.controller.stop()
        await harness.controller.waitForWork()

        #expect(harness.controller.phase == .failed(error.localizedDescription))
        #expect(harness.sounds.played == [.system("Tink"), .system("Basso")])
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test("an empty transcript pastes nothing and says nothing was heard")
    func emptyTextIsNotPasted() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.engine.state.withLock { $0.text = " \n " }

        #expect(await harness.startListening())
        harness.audio.samples = FakeAudioSource.speech(seconds: 1)
        harness.controller.stop()
        await harness.controller.waitForWork()

        #expect(harness.controller.phase == .failed(DictationError.nothingHeard.localizedDescription))
        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.sounds.played == [.system("Tink"), .system("Basso")])
    }

    @Test("without Accessibility the text stays on the clipboard and the user is told")
    func copiedOnlyIsReported() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.inserter.result = .copiedOnly

        #expect(await harness.startListening())
        harness.audio.samples = FakeAudioSource.speech(seconds: 1)
        harness.controller.stop()
        await harness.controller.waitForWork()

        guard case let .failed(message) = harness.controller.phase else {
            Issue.record("Expected a failure, got \(harness.controller.phase)")
            return
        }
        #expect(message.contains("clipboard"))
        #expect(harness.controller.lastTranscript == "Hallo Welt")
    }

    @Test("cancelling while listening drops the audio and ignores late buffers")
    func cancelWhileListening() async throws {
        let harness = DictationHarness { $0.ducksAudio = true }
        defer { harness.tearDown() }

        harness.controller.start()
        harness.controller.cancel()
        harness.audio.deliverFirstAudio()
        try await Task.sleep(for: .milliseconds(100))

        #expect(harness.controller.phase == .idle)
        #expect(harness.audio.cancelCount == 1)
        #expect(harness.ducker.restoreCount == 1)
        #expect(harness.sounds.played.isEmpty)
        #expect(harness.ducker.levels.isEmpty)
    }

    // MARK: - Shortcut and settings

    @Test("the shortcut starts and stops in hold mode, but not while a new one is recorded")
    func shortcutDrivesTheController() async {
        let harness = DictationHarness { $0.mode = .hold }
        defer { harness.tearDown() }
        let controller = harness.controller

        controller.isCapturingShortcut = true
        controller.handle(.pressed)
        #expect(controller.phase == .idle)
        controller.handle(.released)
        controller.isCapturingShortcut = false

        controller.handle(.pressed)
        #expect(controller.phase == .listening)
        harness.audio.samples = FakeAudioSource.speech(seconds: 1)
        harness.clock.now = 1
        controller.handle(.released)
        #expect(controller.phase == .transcribing)
        await controller.waitForWork()
        #expect(harness.inserter.inserted == ["Hallo Welt"])
    }

    @Test("an interrupted press cancels the dictation")
    func interruptionCancels() {
        let harness = DictationHarness()
        defer { harness.tearDown() }

        harness.controller.handle(.pressed)
        #expect(harness.controller.phase == .listening)
        harness.controller.handle(.interrupted)
        #expect(harness.controller.phase == .idle)
        #expect(harness.audio.cancelCount == 1)
    }

    @Test("changes are saved, and shortcut changes are reported")
    func updateSavesAndReports() {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        let reports = Counter()
        harness.controller.onShortcutConfigurationChange = { reports.value += 1 }

        harness.controller.update { $0.shortcut = .modifier(.rightOption) }
        #expect(reports.value == 1)
        #expect(DictationSettingsStore(defaults: harness.defaults).load().shortcut == .modifier(.rightOption))

        harness.controller.update { $0.doneSound = .system("Glass") }
        #expect(reports.value == 1)
        #expect(DictationSettingsStore(defaults: harness.defaults).load().doneSound == .system("Glass"))

        harness.controller.update { $0.doneSound = .system("Glass") }
        #expect(reports.value == 1)
    }

    @Test("turning dictation off ends a running dictation and unloads the model")
    func disablingStops() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }

        harness.controller.start()
        harness.controller.update { $0.isEnabled = false }

        #expect(harness.controller.phase == .idle)
        #expect(harness.audio.cancelCount == 1)
        #expect(await eventually { harness.engine.state.withLock { $0.shutdownCount } == 1 })
        harness.controller.start()
        #expect(harness.controller.phase == .idle)
    }

    // MARK: - Engine

    @Test("activating loads an installed model")
    func activateLoadsTheModel() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }

        harness.controller.activate()

        #expect(harness.controller.isAccessibilityTrusted)
        #expect(await eventually { harness.controller.engineState == .ready })
        #expect(harness.engine.state.withLock { $0.prepared } == [CohereModel.recommended.id])
    }

    @Test("activating tells the engine how long to keep the model")
    func activatePassesRetention() async {
        let harness = DictationHarness { $0.modelRetention = .fifteenMinutes }
        defer { harness.tearDown() }

        harness.controller.activate()
        #expect(await eventually { harness.engine.state.withLock { $0.idleLimits } == [.seconds(900)] })

        harness.controller.update { $0.modelRetention = .always }
        #expect(await eventually { harness.engine.state.withLock { $0.idleLimits } == [.seconds(900), nil] })
    }

    @Test("with idle unloading, listening loads the model again")
    func listeningWarmsUpTheModel() async {
        let harness = DictationHarness { $0.modelRetention = .fiveMinutes }
        defer { harness.tearDown() }

        #expect(await harness.startListening())
        #expect(await eventually { harness.engine.state.withLock { $0.prepared } == [CohereModel.recommended.id] })
    }

    @Test("a model kept loaded is not warmed up again on every dictation")
    func noWarmUpWhenKeptLoaded() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }

        #expect(await harness.startListening())
        harness.audio.samples = FakeAudioSource.speech(seconds: 1)
        harness.controller.stop()
        await harness.controller.waitForWork()
        #expect(harness.engine.state.withLock { $0.prepared }.isEmpty)
    }

    @Test("installing a missing model loads it afterwards")
    func installThenLoad() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.engine.state.withLock { $0.isInstalled = false }

        harness.controller.activate()
        #expect(harness.controller.engineState == .notInstalled)

        harness.controller.installModel()
        #expect(await eventually { harness.controller.engineState == .ready })
        #expect(harness.engine.state.withLock { $0.installed } == [CohereModel.recommended.id])
    }
}
