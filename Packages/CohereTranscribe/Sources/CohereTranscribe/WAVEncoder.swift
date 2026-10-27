import Foundation

/// Encodes mono float samples as a 16-bit PCM WAV file, the format every
/// transcription server accepts without a decoder.
public enum WAVEncoder {
    public static func encode(samples: [Float], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataSize)
        data.append(Data("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + dataSize))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * bytesPerSample))
        data.appendLittleEndian(UInt16(bytesPerSample))
        data.appendLittleEndian(UInt16(16))
        data.append(Data("data".utf8))
        data.appendLittleEndian(UInt32(dataSize))
        let pcm = samples.map { sample -> Int16 in
            let clamped = sample.isFinite ? max(-1, min(1, sample)) : 0
            return Int16(clamped * Float(Int16.max)).littleEndian
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: some FixedWidthInteger) {
        // Qualified: inside a Data extension the bare name finds Data's own method.
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
