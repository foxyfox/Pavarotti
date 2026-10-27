import BiscottiTestSupport
import Dictation
import Testing
@testable import OnboardingUI

@Suite("OnboardingViewModel -- Cohere dictation row")
@MainActor
struct OnboardingDictationRowTests {
    private static var download: DictationInstallPlan {
        DictationInstallPlan(downloadBytes: 1_800_000_000, copiesModelFromTypeWhisper: false)
    }

    private static var copy: DictationInstallPlan {
        DictationInstallPlan(downloadBytes: 16_000_000, copiesModelFromTypeWhisper: true)
    }

    private func state(
        _ engine: DictationController.EngineState,
        isReady: Bool = false,
        plan: DictationInstallPlan? = OnboardingDictationRowTests.download,
        availableBytes: Int64 = .max
    ) -> ModelRowState {
        let facts = plan.map { DictationRowFacts(plan: $0, availableBytes: availableBytes) }
        return OnboardingViewModel.dictationRowState(engine: engine, isReady: isReady, facts: facts)
    }

    @Test("before an install the row shows the download size, or TypeWhisper's copy")
    func idle() {
        #expect(state(.notInstalled) == .idle(sizeCaption: "~1.8 GB"))
        #expect(state(.notInstalled, plan: Self.copy) == .idle(sizeCaption: "Copied from TypeWhisper"))
    }

    @Test("while the step is prepared the row is checking")
    func checking() {
        #expect(state(.notInstalled, plan: nil) == .checking)
    }

    @Test("too little disk space for the download blocks it")
    func insufficientDisk() {
        #expect(state(.notInstalled, availableBytes: 1_000_000_000) == .insufficientDisk)
        #expect(state(.notInstalled, plan: Self.copy, availableBytes: 1_000_000_000) == .idle(sizeCaption: "Copied from TypeWhisper"))
    }

    @Test("installing, failed and ready follow the engine")
    func engineStates() {
        #expect(state(.installing(0.25)) == .downloading(.determinate(fraction: 0.25)))
        #expect(state(.failed("Offline")) == .failed(message: "Offline"))
        #expect(state(.ready, isReady: true) == .ready)
        #expect(state(.failed("Did not load"), isReady: true) == .ready)
    }

    @Test("without dictation the step behaves as before")
    func withoutDictation() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        #expect(model.dictation == nil)
        #expect(model.dictationRowState() == .ready)
        #expect(model.accessibilityGranted)
        #expect(model.allModelsStarted == model.bothModelsStarted)
        #expect(model.allModelsReady == model.bothModelsReady)
    }
}
