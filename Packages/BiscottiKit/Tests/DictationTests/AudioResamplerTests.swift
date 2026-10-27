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
