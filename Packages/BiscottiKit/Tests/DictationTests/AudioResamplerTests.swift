import Foundation
import Testing
@testable import Dictation

@Suite("AudioResampler")
struct AudioResamplerTests {
    @Test("48 kHz becomes 16 kHz at a third of the length")
    func downsamples() {
        let step = 2 * Double.pi * 440 / 48000
        let source = (0 ..< 48000).map { Float(sin(Double($0) * step) * 0.5) }
        let output = AudioResampler.resample(source, from: 48000, to: 16000)
        #expect(abs(output.count - 16000) <= 160)
        let peak = output.map(abs).max() ?? 0
        #expect(peak > 0.4)
        #expect(peak < 0.6)
    }

    @Test("the same rate passes through untouched")
    func sameRate() {
        let source: [Float] = [0, 0.25, -0.25, 1]
        #expect(AudioResampler.resample(source, from: 16000, to: 16000) == source)
    }

    @Test("nothing in, nothing out")
    func emptyInput() {
        #expect(AudioResampler.resample([], from: 48000, to: 16000).isEmpty)
        #expect(AudioResampler.resample([1], from: 0, to: 16000).isEmpty)
    }
}

/// Pavarotti: a dictation whose microphone changes its format while recording, like
/// AirPods switching to their headset profile.
@Suite("RecordedAudio")
struct RecordedAudioTests {
    @Test("audio from before and after a format change is joined at 16 kHz")
    func joinsFormats() {
        var audio = RecordedAudio(sampleRate: 48000)
        audio.samples = Self.tone(seconds: 0.5, rate: 48000)
        audio.switchFormat(to: 24000)
        audio.samples = Self.tone(seconds: 1, rate: 24000)

        let joined = audio.resampled

        #expect(abs(joined.count - 24000) <= 240)
        let peak = joined.map(abs).max() ?? 0
        #expect(peak > 0.4)
        #expect(peak < 0.6)
    }

    @Test("a change before any audio loses nothing")
    func changeBeforeAudio() {
        var audio = RecordedAudio(sampleRate: 48000)
        audio.switchFormat(to: 16000)
        audio.samples = [0, 0.25, -0.25, 1]

        #expect(audio.resampled == [0, 0.25, -0.25, 1])
    }

    private static func tone(seconds: Double, rate: Double) -> [Float] {
        let step = 2 * Double.pi * 440 / rate
        return (0 ..< Int(seconds * rate)).map { Float(sin(Double($0) * step) * 0.5) }
    }
}
