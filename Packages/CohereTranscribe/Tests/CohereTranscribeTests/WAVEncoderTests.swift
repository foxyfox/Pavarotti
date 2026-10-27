import Foundation
import Testing
@testable import CohereTranscribe

@Suite("WAV encoder")
struct WAVEncoderTests {
    @Test("Header describes 16-bit mono PCM at the given rate")
    func header() {
        let data = WAVEncoder.encode(samples: [0, 0.5, -0.5, 1], sampleRate: 16000)
        #expect(data.count == 44 + 8)
        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(data.subdata(in: 8 ..< 16) == Data("WAVEfmt ".utf8))
        #expect(readUInt32(data, at: 4) == 36 + 8)
        #expect(readUInt16(data, at: 20) == 1)
        #expect(readUInt16(data, at: 22) == 1)
        #expect(readUInt32(data, at: 24) == 16000)
        #expect(readUInt32(data, at: 28) == 32000)
        #expect(readUInt16(data, at: 34) == 16)
        #expect(data.subdata(in: 36 ..< 40) == Data("data".utf8))
        #expect(readUInt32(data, at: 40) == 8)
    }

    @Test("Samples are clamped and scaled to Int16")
    func samples() {
        let data = WAVEncoder.encode(samples: [0, 1, -1, 2], sampleRate: 16000)
        #expect(readInt16(data, at: 44) == 0)
        #expect(readInt16(data, at: 46) == Int16.max)
        #expect(readInt16(data, at: 48) == -Int16.max)
        #expect(readInt16(data, at: 50) == Int16.max)
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func readInt16(_ data: Data, at offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(data, at: offset))
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { value, index in
            value | UInt32(data[offset + index]) << (8 * UInt32(index))
        }
    }
}
