import CohereTranscribe
import Testing
@testable import Dictation

@Suite("Model setup")
@MainActor
struct DictationSetupTests {
    private static var fromTypeWhisper: DictationInstallPlan {
        DictationInstallPlan(downloadBytes: 16_000_000, copiesModelFromTypeWhisper: true)
    }

    @Test("the setup picks the model TypeWhisper already downloaded")
    func prefersTypeWhisperCopy() {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.engine.state.withLock { state in
            state.isInstalled = false
            state.plans[CohereModel.precise.id] = Self.fromTypeWhisper
        }

        harness.controller.preferTypeWhisperModel()

        #expect(harness.controller.settings.modelID == CohereModel.precise.id)
        #expect(harness.controller.installPlan == Self.fromTypeWhisper)
    }

    @Test("with several models in TypeWhisper, the recommended one wins")
    func recommendedFirst() {
        let harness = DictationHarness { $0.modelID = CohereModel.compact.id }
        defer { harness.tearDown() }
        harness.engine.state.withLock { state in
            state.isInstalled = false
            state.plans[CohereModel.maximum.id] = Self.fromTypeWhisper
            state.plans[CohereModel.recommended.id] = Self.fromTypeWhisper
        }

        harness.controller.preferTypeWhisperModel()

        #expect(harness.controller.settings.modelID == CohereModel.recommended.id)
    }

    @Test("an installed model and an empty TypeWhisper keep the choice")
    func keepsChoice() {
        let installed = DictationHarness()
        defer { installed.tearDown() }
        installed.engine.state.withLock { $0.plans[CohereModel.precise.id] = Self.fromTypeWhisper }
        installed.controller.preferTypeWhisperModel()
        #expect(installed.controller.settings.modelID == CohereModel.recommended.id)

        let nothingFound = DictationHarness()
        defer { nothingFound.tearDown() }
        nothingFound.engine.state.withLock { $0.isInstalled = false }
        nothingFound.controller.preferTypeWhisperModel()
        #expect(nothingFound.controller.settings.modelID == CohereModel.recommended.id)
        #expect(nothingFound.controller.installPlan.downloadBytes == 1_000_000)
    }
}
