import Foundation

/// Cuts a long recording into pieces the transcription server takes in one request.
///
/// Each cut falls on the quietest moment shortly before the target length, so it rarely
/// splits a word. Pieces come out as soon as enough audio has arrived, so a long file is
/// never held in memory as a whole, and a dictation in between waits for one piece at most.
struct AudioChunker {
    struct Chunk: Equatable {
        /// Position of the first sample in the whole recording.
        let offset: Int
        let samples: [Float]
    }

    let targetLength: Int
    /// How far before the target length a cut may fall.
    let searchLength: Int
    /// The loudness is compared in frames of this many samples.
    let frameLength: Int
    private var buffer: [Float] = []
    private var bufferOffset = 0

    /// Lengths in seconds.
    init(sampleRate: Int, target: TimeInterval = 120, search: TimeInterval = 20, frame: TimeInterval = 0.1) {
        let rate = Double(sampleRate)
        targetLength = max(1, Int(target * rate))
        searchLength = min(targetLength, max(0, Int(search * rate)))
        frameLength = max(1, Int(frame * rate))
    }

    /// Adds samples and returns the pieces that are complete now.
    mutating func append(_ samples: [Float]) -> [Chunk] {
        buffer.append(contentsOf: samples)
        var chunks: [Chunk] = []
        while buffer.count >= targetLength {
            let cut = Self.quietestCut(
                in: buffer,
                from: targetLength - searchLength,
                to: targetLength,
                frameLength: frameLength
            )
            chunks.append(Chunk(offset: bufferOffset, samples: Array(buffer[..<cut])))
            buffer.removeFirst(cut)
            bufferOffset += cut
        }
        return chunks
    }

    /// The rest of the recording, `nil` when nothing is left.
    mutating func finish() -> Chunk? {
        guard !buffer.isEmpty else { return nil }
        let chunk = Chunk(offset: bufferOffset, samples: buffer)
        bufferOffset += buffer.count
        buffer = []
        return chunk
    }

    /// The middle of the quietest frame between `lower` and `upper`, or `upper` when no
    /// whole frame fits. Never 0, so every piece holds audio.
    static func quietestCut(in samples: [Float], from lower: Int, to upper: Int, frameLength: Int) -> Int {
        var best = upper
        var bestEnergy = Float.infinity
        var start = max(0, lower)
        while start + frameLength <= upper {
            var energy: Float = 0
            for index in start ..< start + frameLength {
                energy += samples[index] * samples[index]
            }
            if energy < bestEnergy {
                bestEnergy = energy
                best = start + frameLength / 2
            }
            start += frameLength
        }
        return max(1, best)
    }
}
