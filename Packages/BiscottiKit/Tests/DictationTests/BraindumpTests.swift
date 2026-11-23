import Foundation
import Synchronization
import Testing
@testable import Dictation

/// Answers with a fixed note or error and records what it was asked.
final class FakeStructurer: DictationTextStructuring {
    struct State {
        var answer = "## Ideen\n\n- Hallo Welt"
        var error: (any Error)?
        var inputs: [String] = []
    }

    let state = Mutex(State())

    func structure(_ text: String) async throws -> String {
        let outcome = state.withLock { current -> Result<String, any Error> in
            current.inputs.append(text)
            if let error = current.error {
                return .failure(error)
            }
            return .success(current.answer)
        }
        return try outcome.get()
    }

    var inputs: [String] {
        state.withLock { $0.inputs }
    }
}

@Suite("Braindump")
@MainActor
struct BraindumpTests {
    /// A harness in toggle mode with a structurer, listening with a second of speech.
    private func listening(configure: (inout DictationSettings) -> Void = { _ in }) -> (DictationHarness, FakeStructurer) {
        let harness = DictationHarness {
            $0.mode = .toggle
            configure(&$0)
        }
        let structurer = FakeStructurer()
        harness.controller.structurer = structurer
        harness.controller.handle(.pressed)
        harness.controller.handle(.released)
        harness.audio.samples = FakeAudioSource.speech(seconds: 1)
        harness.clock.now = 1
        return (harness, structurer)
    }

    @Test("a second press right after the stopping one pastes the structured note")
    func doublePressStructures() async {
        let (harness, structurer) = listening()
        defer { harness.tearDown() }
        let controller = harness.controller

        controller.handle(.pressed)
        controller.handle(.released)
        #expect(controller.phase == .transcribing)
        harness.clock.now = 1.2
        controller.handle(.pressed)
        controller.handle(.released)
        #expect(controller.isBraindump)
        #expect(controller.phase == .transcribing)

        await controller.waitForWork()
        #expect(structurer.inputs == ["Hallo Welt"])
        #expect(harness.inserter.inserted == ["## Ideen\n\n- Hallo Welt"])
        #expect(controller.lastTranscript == "## Ideen\n\n- Hallo Welt")
        #expect(controller.phase == .idle)

        // The swallowed press did not leave the shortcut half-pressed: the next press starts.
        controller.handle(.pressed)
        #expect(controller.phase == .listening)
        #expect(!controller.isBraindump)
    }

    @Test("a single press pastes the text as spoken once the window passed")
    func singlePressStaysAsSpoken() async {
        let (harness, structurer) = listening()
        defer { harness.tearDown() }
        let controller = harness.controller

        controller.handle(.pressed)
        controller.handle(.released)
        await controller.waitForWork()

        #expect(structurer.inputs.isEmpty)
        #expect(harness.inserter.inserted == ["Hallo Welt"])
        #expect(!controller.isBraindump)
    }

    @Test("a press after the window is not a double press")
    func latePressIsIgnored() async {
        let (harness, structurer) = listening()
        defer { harness.tearDown() }
        let controller = harness.controller

        controller.handle(.pressed)
        controller.handle(.released)
        harness.clock.now = 2
        controller.handle(.pressed)
        #expect(!controller.isBraindump)
        controller.handle(.released)
        await controller.waitForWork()

        #expect(structurer.inputs.isEmpty)
        #expect(harness.inserter.inserted == ["Hallo Welt"])
    }

    @Test("when the model fails, the text is pasted as spoken with a notice")
    func failureFallsBack() async {
        let (harness, structurer) = listening()
        defer { harness.tearDown() }
        let controller = harness.controller
        structurer.state.withLock { $0.error = BraindumpError.noModel }

        controller.handle(.pressed)
        controller.handle(.released)
        controller.handle(.pressed)
        controller.handle(.released)
        await controller.waitForWork()

        #expect(harness.inserter.inserted == ["Hallo Welt"])
        #expect(controller.phase == .idle)
        #expect(controller.notice?.hasPrefix("Not structured:") == true)
    }

    @Test("with braindumps turned off a double press does not structure")
    func switchedOff() async {
        let (harness, structurer) = listening { $0.structuresOnDoublePress = false }
        defer { harness.tearDown() }
        let controller = harness.controller

        controller.handle(.pressed)
        controller.handle(.released)
        controller.handle(.pressed)
        #expect(!controller.isBraindump)
        await controller.waitForWork()

        #expect(structurer.inputs.isEmpty)
        #expect(harness.inserter.inserted == ["Hallo Welt"])
    }

    @Test("a code fence around the answer is removed")
    func cleanedAnswer() {
        #expect(Braindump.cleaned("```markdown\n## Plan\n- eins\n```\n") == "## Plan\n- eins")
        #expect(Braindump.cleaned("  - eins\n- zwei  ") == "- eins\n- zwei")
        #expect(Braindump.cleaned("```") == "```")
    }

    @Test("older settings without the braindump switch turn it on")
    func settingDefaultsOn() throws {
        let data = Data("{\"isEnabled\":true}".utf8)
        let settings = try JSONDecoder().decode(DictationSettings.self, from: data)
        #expect(settings.structuresOnDoublePress)
    }
}
