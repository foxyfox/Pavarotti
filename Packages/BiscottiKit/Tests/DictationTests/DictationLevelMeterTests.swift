import Foundation
import Testing
@testable import Dictation

@Suite("Recording bubble levels")
@MainActor
struct DictationLevelMeterTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    @Test("loudness maps -55 dBFS and below to 0 and -10 dBFS and above to 1")
    func meterLevel() {
        #expect(DictationAudio.meterLevel(rms: 0) == 0)
        #expect(DictationAudio.meterLevel(rms: 0.001) == 0)
        #expect(DictationAudio.meterLevel(rms: 1) == 1)
        #expect(abs(DictationAudio.meterLevel(rms: 0.01) - 15.0 / 45.0) < 0.0001)
    }

    @Test("rms of a constant signal is its magnitude")
    func rms() {
        #expect(DictationAudio.rms([]) == 0)
        #expect(abs(DictationAudio.rms([0.5, -0.5, 0.5, -0.5]) - 0.5) < 0.0001)
    }

    @Test("new levels come in on the right; rising at once, falling eased")
    func record() {
        let meter = DictationLevelMeter()
        meter.start(at: start)

        meter.record(0.8, at: start)
        #expect(meter.levels.count == DictationLevelMeter.barCount)
        #expect(meter.levels.last == 0.8)
        #expect(meter.levels.first == 0)

        meter.record(0, at: start)
        #expect(meter.levels.last == 0.4)
        #expect(meter.levels[DictationLevelMeter.barCount - 2] == 0.8)

        meter.record(3, at: start)
        #expect(meter.levels.last == 1)
    }

    @Test("the timer runs from the start and a new dictation clears everything")
    func timer() {
        let meter = DictationLevelMeter()
        meter.start(at: start)
        meter.record(0.5, at: start.addingTimeInterval(67.4))
        #expect(meter.elapsedText == "1:07")

        meter.start(at: start)
        #expect(meter.elapsedText == "0:00")
        #expect(meter.levels.allSatisfy { $0 == 0 })
    }

    @Test("the controller reads the level from the microphone")
    func inputLevel() {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.audio.level = 0.6
        #expect(harness.controller.inputLevel == 0.6)
    }
}
