import Foundation
import Testing
@testable import Dictation

@Suite("Dictation microphone")
@MainActor
struct DictationMicrophoneTests {
    @Test("the first press asks for microphone access and does not listen yet")
    func asksForPermissionFirst() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.microphones.permission = .undecided

        harness.controller.start()
        await harness.controller.waitForMicrophoneRequest()

        #expect(harness.microphones.requestCount == 1)
        #expect(harness.audio.startCount == 0)
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.microphonePermission == .granted)

        #expect(await harness.startListening())
        #expect(harness.controller.phase == .listening)
        #expect(harness.microphones.requestCount == 1)
    }

    @Test("a denied prompt is reported")
    func deniedPrompt() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.microphones.permission = .undecided
        harness.microphones.grantsOnRequest = false

        harness.controller.start()
        await harness.controller.waitForMicrophoneRequest()

        #expect(harness.controller.phase == .failed(DictationError.microphoneDenied.localizedDescription))
        #expect(harness.controller.microphonePermission == .denied)
        #expect(harness.audio.startCount == 0)
    }

    @Test("without access the microphone is not started and the user is told")
    func deniedAccess() {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.microphones.permission = .denied

        harness.controller.start()

        #expect(harness.controller.phase == .failed(DictationError.microphoneDenied.localizedDescription))
        #expect(harness.microphones.requestCount == 0)
        #expect(harness.audio.startCount == 0)
        #expect(harness.sounds.played == [.system("Basso")])
    }

    @Test("a silent recording is not transcribed and the user is told")
    func silentRecording() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }

        #expect(await harness.startListening())
        harness.audio.samples = FakeAudioSource.silence(seconds: 1)
        harness.controller.stop()

        #expect(harness.controller.phase == .failed(DictationError.silentMicrophone.localizedDescription))
        #expect(harness.engine.state.withLock { $0.requests }.isEmpty)
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test("silence is a peak below -100 dBFS")
    func silenceThreshold() {
        #expect(DictationAudio.isSilent([]))
        #expect(DictationAudio.isSilent([0, 0.000_001, -0.000_009]))
        #expect(!DictationAudio.isSilent([0, 0, -0.000_02]))
        #expect(!DictationAudio.isSilent(FakeAudioSource.speech(seconds: 0.1)))
    }

    @Test("the chosen microphone is recorded, the system default by default")
    func chosenMicrophone() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }

        #expect(await harness.startListening())
        harness.controller.cancel()
        harness.controller.chooseMicrophone(FakeMicrophones.display)
        #expect(await harness.startListening())

        #expect(harness.audio.microphoneIDs == [nil, FakeMicrophones.display.id])
        #expect(DictationSettingsStore(defaults: harness.defaults).load().microphone == FakeMicrophones.display)
    }

    @Test("Settings lists the microphones and tells when the choice is not connected")
    func listsMicrophones() {
        let harness = DictationHarness {
            $0.microphone = FakeMicrophones.display
        }
        defer { harness.tearDown() }
        let controller = harness.controller

        controller.refreshMicrophones()
        #expect(controller.microphones == [FakeMicrophones.builtIn, FakeMicrophones.display])
        #expect(controller.defaultMicrophone == FakeMicrophones.builtIn)
        #expect(controller.isChosenMicrophoneConnected)

        harness.microphones.connected = [FakeMicrophones.builtIn]
        controller.refreshMicrophones()
        #expect(!controller.isChosenMicrophoneConnected)
        #expect(controller.settings.microphone == FakeMicrophones.display)

        controller.chooseMicrophone(nil)
        #expect(controller.isChosenMicrophoneConnected)
    }
}
