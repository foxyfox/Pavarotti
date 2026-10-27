import Testing
@testable import Dictation

@Suite("Audio chunker")
struct AudioChunkerTests {
    /// 10 samples per second keeps the arrays small: target 10 s, search 3 s, frame 1 s.
    private func makeChunker() -> AudioChunker {
        AudioChunker(sampleRate: 10, target: 10, search: 3, frame: 1)
    }

    private func loud(_ count: Int) -> [Float] {
        Array(repeating: 0.5, count: count)
    }

    @Test("Audio shorter than one piece comes out whole at the end")
    func shortAudio() {
        var chunker = makeChunker()
        let early = chunker.append(loud(42))
        let rest = chunker.finish()
        let after = chunker.finish()
        #expect(early.isEmpty)
        #expect(rest == AudioChunker.Chunk(offset: 0, samples: loud(42)))
        #expect(after == nil)
    }

    @Test("A cut falls into the quiet moment before the target length")
    func cutsAtQuietMoment() {
        var chunker = makeChunker()
        // Quiet from 8 to 9 seconds, inside the search window of 7 to 10 seconds.
        let audio = loud(80) + Array(repeating: 0, count: 10) + loud(60)
        let chunks = chunker.append(audio)
        #expect(chunks.count == 1)
        #expect(chunks.first?.offset == 0)
        #expect(chunks.first?.samples.count == 85)
        let rest = chunker.finish()
        #expect(rest?.offset == 85)
    }

    @Test("Pieces arriving in parts come out contiguous and complete")
    func contiguousPieces() {
        var chunker = makeChunker()
        let audio = (0 ..< 357).map { Float($0 % 7) / 10 }
        var chunks: [AudioChunker.Chunk] = []
        for start in stride(from: 0, to: audio.count, by: 23) {
            chunks += chunker.append(Array(audio[start ..< min(start + 23, audio.count)]))
        }
        if let rest = chunker.finish() {
            chunks.append(rest)
        }
        #expect(chunks.flatMap(\.samples) == audio)
        var expectedOffset = 0
        for chunk in chunks {
            #expect(chunk.offset == expectedOffset)
            #expect(chunk.samples.count <= 100)
            expectedOffset += chunk.samples.count
        }
    }

    @Test("Without a whole frame in the window the cut falls at the target")
    func cutWithoutFrame() {
        #expect(AudioChunker.quietestCut(in: loud(10), from: 9, to: 10, frameLength: 5) == 10)
    }
}
