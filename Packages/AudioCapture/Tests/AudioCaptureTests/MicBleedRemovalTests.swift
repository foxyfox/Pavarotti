import Accelerate
import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import AudioCapture

/// Deterministic test signals: a far side that plays through a loudspeaker and
/// reaches the microphone delayed and coloured, and a near side that only the
/// microphone hears.
private enum BleedFixture {
    static let rate = 24000.0
    static let delaySamples = 7920 // 0.33 s, a Bluetooth speaker
    static let seconds = 40

    /// Noise bursts of about 300 ms, low-passed: the rhythm and spectrum of speech.
    static func speechLike(seed: UInt64, activeSeconds: [Range<Int>]) -> [Float] {
        var state = seed
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
        }
        var samples = [Float](repeating: 0, count: seconds * Int(rate))
        var lowPassed: Float = 0
        var level: Float = 0
        for index in samples.indices {
            if index % 7200 == 0 { level = next() > -0.3 ? 0.2 + 0.2 * abs(next()) : 0 }
            lowPassed += 0.35 * (next() - lowPassed)
            let second = index / Int(rate)
            let active = activeSeconds.contains { $0.contains(second) }
            samples[index] = active ? lowPassed * level : 0
        }
        return samples
    }

    /// The far side as the microphone picks it up from the loudspeaker.
    static func bleed(of reference: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: reference.count)
        for index in delaySamples ..< reference.count {
            let source = index - delaySamples
            var value = reference[source]
            if source >= 40 { value += 0.5 * reference[source - 40] }
            if source >= 130 { value -= 0.3 * reference[source - 130] }
            output[index] = 0.25 * value
        }
        return output
    }

    static func levelDB(_ samples: [Float], seconds range: Range<Int>) -> Float {
        let slice = Array(samples[range.lowerBound * Int(rate) ..< range.upperBound * Int(rate)])
        return 10 * log10(vDSP.meanSquare(slice) + 1e-12)
    }

    /// Runs the whole track through the remover in one block.
    static func clean(mic: [Float], reference: [Float]) -> MicBleedRemover.BlockResult {
        let lead = [Float](repeating: 0, count: MicBleedRemover.referenceLead)
        return MicBleedRemover().clean(mic: mic, reference: lead + reference, sampleRate: rate)
    }
}

@Suite("MicBleedRemover")
struct MicBleedRemoverTests {
    @Test("far side is removed, near side survives")
    func removesBleedKeepsNearSide() {
        let reference = BleedFixture.speechLike(seed: 1, activeSeconds: [5 ..< 15, 25 ..< 35])
        let near = BleedFixture.speechLike(seed: 2, activeSeconds: [16 ..< 22])
        let bleed = BleedFixture.bleed(of: reference)
        let mic = vDSP.add(near, bleed)

        let result = BleedFixture.clean(mic: mic, reference: reference)

        #expect(result.cleaned)
        #expect(abs((result.delaySeconds ?? 0) - 0.33) < 0.03)
        let before = BleedFixture.levelDB(mic, seconds: 6 ..< 14)
        let after = BleedFixture.levelDB(result.samples, seconds: 6 ..< 14)
        #expect(before - after > 15, "bleed reduced by \(before - after) dB")
        let nearBefore = BleedFixture.levelDB(near, seconds: 16 ..< 22)
        let nearAfter = BleedFixture.levelDB(result.samples, seconds: 16 ..< 22)
        #expect(abs(nearBefore - nearAfter) < 0.5)
        let difference = zip(result.samples, near).map { $0 - $1 }
        #expect(BleedFixture.levelDB(difference, seconds: 16 ..< 22) < nearBefore - 25)
    }

    @Test("a silent reference leaves the microphone untouched")
    func silentReferenceIsUntouched() {
        let near = BleedFixture.speechLike(seed: 2, activeSeconds: [0 ..< 40])
        let silence = [Float](repeating: 0, count: near.count)
        let result = BleedFixture.clean(mic: near, reference: silence)
        #expect(!result.cleaned)
        #expect(result.samples == near)
    }

    @Test("headphones: far side not in the microphone, nothing is touched")
    func unrelatedReferenceIsUntouched() {
        let reference = BleedFixture.speechLike(seed: 1, activeSeconds: [0 ..< 40])
        let near = BleedFixture.speechLike(seed: 2, activeSeconds: [0 ..< 40])
        let result = BleedFixture.clean(mic: near, reference: reference)
        #expect(!result.cleaned)
        #expect(result.samples == near)
    }

    @Test("solves a small Hermitian system")
    func solvesHermitianSystem() {
        var matrix = [
            ComplexValue(real: 4, imag: 0), ComplexValue(real: 1, imag: 2),
            ComplexValue(real: 1, imag: -2), ComplexValue(real: 6, imag: 0)
        ]
        var vector = [ComplexValue(real: 1, imag: 1), ComplexValue(real: 2, imag: -1)]
        let original = matrix
        let expected = vector
        let solution = ComplexValue.solve(matrix: &matrix, vector: &vector, count: 2)
        for row in 0 ..< 2 {
            let value = original[row * 2] * solution[0] - (ComplexValue.zero - original[row * 2 + 1] * solution[1])
            #expect(abs(value.real - expected[row].real) < 1e-9)
            #expect(abs(value.imag - expected[row].imag) < 1e-9)
        }
    }
}

@Suite("MicTrackCleaner")
struct MicTrackCleanerTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bleed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes real 24 kHz ADTS AAC, the format recordings use.
    private func write(_ samples: [Float], to url: URL) throws {
        let writer = try TrackWriter(url: url, encoder: .voice, skipping: 0, gain: 1)
        try writer.write(samples)
    }

    private func read(_ url: URL) throws -> [Float] {
        let reader = try TrackReader(url: url, format: EncoderSettings.voice.processingFormat)
        var samples: [Float] = []
        while true {
            let chunk = try reader.read(48000)
            if chunk.isEmpty { return samples }
            samples += chunk
        }
    }

    /// Lag (in samples) at which `candidate` matches `original` best.
    private func lag(of candidate: [Float], against original: [Float], around start: Int) -> Int {
        let length = 24000
        let template = Array(original[start ..< start + length])
        var best = (lag: 0, value: -Float.infinity)
        for lag in -400 ... 400 {
            let value = vDSP.dot(template, candidate[(start + lag) ..< (start + lag + length)])
            if value > best.value { best = (lag, value) }
        }
        return best.lag
    }

    @Test("cleans real AAC tracks and keeps them aligned")
    func cleansFilesInPlace() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let micURL = directory.appendingPathComponent("mic.aac")
        let systemURL = directory.appendingPathComponent("system.aac")
        let reference = BleedFixture.speechLike(seed: 1, activeSeconds: [5 ..< 15, 25 ..< 35])
        let near = BleedFixture.speechLike(seed: 2, activeSeconds: [16 ..< 22])
        try write(vDSP.add(near, BleedFixture.bleed(of: reference)), to: micURL)
        try write(reference, to: systemURL)
        let before = try read(micURL)

        let summary = try MicTrackCleaner.clean(mic: micURL, system: systemURL, keepRaw: true)
        let after = try read(micURL)

        #expect(summary.replaced)
        #expect(summary.cleanedBlocks == summary.blocks)
        #expect(abs((summary.delaySeconds ?? 0) - 0.33) < 0.03)
        #expect(abs(after.count - before.count) <= 2048)
        #expect(BleedFixture.levelDB(before, seconds: 6 ..< 14) - BleedFixture.levelDB(after, seconds: 6 ..< 14) > 15)
        #expect(lag(of: after, against: before, around: 18 * 24000) == 0)
        let raw = directory.appendingPathComponent(MicTrackCleaner.rawCopyName)
        #expect(FileManager.default.fileExists(atPath: raw.path))
    }

    @Test("a track without bleed at a good level is not rewritten")
    func leavesCleanTrackAlone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let micURL = directory.appendingPathComponent("mic.aac")
        let systemURL = directory.appendingPathComponent("system.aac")
        try write(BleedFixture.speechLike(seed: 2, activeSeconds: [0 ..< 40]), to: micURL)
        try write(BleedFixture.speechLike(seed: 1, activeSeconds: [0 ..< 40]), to: systemURL)
        let before = try Data(contentsOf: micURL)

        let summary = try MicTrackCleaner.clean(mic: micURL, system: systemURL, keepRaw: true)

        #expect(!summary.replaced)
        #expect(summary.cleanedBlocks == 0)
        #expect(try Data(contentsOf: micURL) == before)
        let raw = directory.appendingPathComponent(MicTrackCleaner.rawCopyName)
        #expect(!FileManager.default.fileExists(atPath: raw.path))
    }

    @Test("a quiet microphone is raised without moving in time")
    func raisesQuietTrack() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let micURL = directory.appendingPathComponent("mic.aac")
        let systemURL = directory.appendingPathComponent("system.aac")
        let quiet = vDSP.multiply(0.02, BleedFixture.speechLike(seed: 2, activeSeconds: [0 ..< 40]))
        try write(quiet, to: micURL)
        try write([Float](repeating: 0, count: quiet.count), to: systemURL)
        let before = try read(micURL)

        let summary = try MicTrackCleaner.clean(mic: micURL, system: systemURL)
        let after = try read(micURL)

        #expect(summary.replaced)
        #expect(summary.gainDB > 6)
        let gained = BleedFixture.levelDB(after, seconds: 5 ..< 35) - BleedFixture.levelDB(before, seconds: 5 ..< 35)
        #expect(abs(Double(gained) - summary.gainDB) < 1)
        #expect(lag(of: after, against: before, around: 18 * 24000) == 0)
    }

    /// Diagnosis on real recordings, off unless `PAVAROTTI_BLEED_DIR` names a
    /// folder holding `<name>-mic.aac` / `<name>-system.aac` pairs. Works on copies.
    @Test("real recordings (manual)", .enabled(if: ProcessInfo.processInfo.environment["PAVAROTTI_BLEED_DIR"] != nil))
    func realRecordings() throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PAVAROTTI_BLEED_DIR"] ?? "")
        let names = try FileManager.default.contentsOfDirectory(atPath: source.path)
            .filter { $0.hasSuffix("-mic.aac") }.map { String($0.dropLast(8)) }.sorted()
        for name in names {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let micURL = directory.appendingPathComponent("mic.aac")
            let systemURL = directory.appendingPathComponent("system.aac")
            try FileManager.default.copyItem(at: source.appendingPathComponent("\(name)-mic.aac"), to: micURL)
            try FileManager.default.copyItem(at: source.appendingPathComponent("\(name)-system.aac"), to: systemURL)
            let summary = try MicTrackCleaner.clean(mic: micURL, system: systemURL)
            let rounded = zip(summary.correlations, summary.explained).map { "\(Int(($0 * 100).rounded()))/\(Int(($1 * 100).rounded()))" }.joined(separator: " ")
            print("REAL \(name): blocks=\(summary.blocks) cleaned=\(summary.cleanedBlocks) delay=\(summary.delaySeconds ?? -1) gain=\(summary.gainDB) took=\(summary.seconds)s\nREAL \(name) corr=\(rounded)")
            if summary.replaced {
                let output = source.appendingPathComponent("\(name)-mic.cleaned.aac")
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.copyItem(at: micURL, to: output)
            }
        }
    }

    @Test("gain is bounded and never lowers a track")
    func gainBounds() {
        #expect(MicTrackCleaner.gain(levels: [], peak: 0) == 1)
        #expect(MicTrackCleaner.gain(levels: [0.0001, 0.0002], peak: 0.001) == 1) // silence
        #expect(MicTrackCleaner.gain(levels: [0.2, 0.3], peak: 0.9) == 1) // loud already
        #expect(MicTrackCleaner.gain(levels: [0.002, 0.002], peak: 0.004) == MicTrackCleaner.maximumGain)
        #expect(abs(MicTrackCleaner.gain(levels: [0.02, 0.02], peak: 0.3) - 3) < 0.01) // peak-limited
    }
}

@Suite("AudioRecorder post-processing")
struct AudioRecorderPostProcessingTests {
    @Test("runs once on the finished files when the recording stops")
    func runsAfterStop() async throws {
        let calls = Mutex<[URL]>([])
        let deviceChanges = FakeDeviceChangeProvider()
        let recorder = AudioRecorder(
            systemEngine: FakeCaptureEngine(),
            micEngine: FakeCaptureEngine(),
            deviceChangeProvider: deviceChanges,
            permissionChecker: FakeSystemPermissionChecker(),
            micPermissionChecker: FakeMicPermissionChecker(),
            postProcessor: { paths in calls.withLock { $0.append(paths.micAAC) } }
        )
        let directory = FileManager.default.temporaryDirectory
        let paths = CapturePaths(
            micAAC: directory.appendingPathComponent("post-mic.aac"),
            systemAAC: directory.appendingPathComponent("post-system.aac")
        )
        try await recorder.start(paths: paths)
        #expect(calls.withLock { $0.isEmpty })
        deviceChanges.finish()
        await recorder.stop()
        await recorder.stop()
        #expect(calls.withLock { $0 } == [paths.micAAC])
    }
}

@Suite("PassiveMicCaptureEngine hardware (manual)")
struct PassiveMicHardwareTests {
    /// Records three seconds from the default microphone on real hardware and
    /// checks that the default output device is not started by it. Off unless
    /// `PAVAROTTI_HARDWARE_MIC` is set; needs microphone permission.
    @Test("listens without starting the output", .enabled(if: ProcessInfo.processInfo.environment["PAVAROTTI_HARDWARE_MIC"] != nil))
    func listensWithoutOutput() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("passive-\(UUID().uuidString).aac")
        defer { try? FileManager.default.removeItem(at: url) }
        let outputID = try #require(CoreAudioHelpers.defaultOutputDeviceID())
        let rateBefore = CoreAudioHelpers.nominalSampleRate(for: outputID)
        let busyBefore = CoreAudioHelpers.isRunningSomewhere(outputID)

        let engine = PassiveMicCaptureEngine(preferredInputUID: {
            ProcessInfo.processInfo.environment["PAVAROTTI_HARDWARE_MIC_UID"]
        })
        let anchor = Mutex<Double>(0)
        engine.setOnFirstBuffer { value in anchor.withLock { $0 = value } }
        try await engine.start(writingTo: url)
        try await Task.sleep(for: .seconds(8))
        let busyDuring = CoreAudioHelpers.isRunningSomewhere(outputID)
        let stopped = Double(AudioConvertHostTimeToNanos(mach_absolute_time())) / 1e9
        await engine.stop()
        print("HARDWARE wall=\(stopped - anchor.withLock { $0 })s")

        let reader = try TrackReader(url: url, format: EncoderSettings.voice.processingFormat)
        let samples = try reader.read(24000 * 20)
        let level = 10 * log10(vDSP.meanSquare(samples) + 1e-12)
        print("HARDWARE frames=\(samples.count) level=\(level)dBFS outputBusy before=\(busyBefore) during=\(busyDuring) rate=\(rateBefore ?? 0)->\(CoreAudioHelpers.nominalSampleRate(for: outputID) ?? 0)")
        #expect(samples.count > 24000 * 2)
        #expect(busyDuring == busyBefore)
        #expect(CoreAudioHelpers.nominalSampleRate(for: outputID) == rateBefore)
    }
}
