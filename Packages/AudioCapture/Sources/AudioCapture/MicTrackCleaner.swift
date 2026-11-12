import Accelerate
import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "MicTrackCleaner")

/// Pavarotti: the pass over the microphone track that runs once a recording has
/// stopped. It removes loudspeaker bleed with the system track as reference
/// (`MicBleedRemover`) and raises a quiet microphone to a usable level. This is
/// the work Apple's voice processing used to do live, moved after the recording
/// so that capturing never touches the devices a call is using.
///
/// The file is rewritten only when something changed. With `keepRaw` the
/// unprocessed track stays next to it as `mic.raw.aac`, for checking the pass
/// against real recordings.
enum MicTrackCleaner {
    /// What the pass did.
    struct Summary: Equatable {
        var blocks = 0
        var cleanedBlocks = 0
        /// Envelope correlation of every block, for diagnosis.
        var correlations: [Float] = []
        /// Share of the microphone predicted from the reference, per block.
        var explained: [Float] = []
        /// Median bleed delay over the cleaned blocks, in seconds.
        var delaySeconds: Double?
        var gainDB: Double = 0
        var seconds: Double = 0
        /// Whether `mic.aac` was replaced by the processed track.
        var replaced = false
    }

    /// Length of one analysis block; consecutive blocks overlap by half.
    static let blockSeconds = 20.0
    /// Samples the AAC encoder puts in front of the audio. Decoding an ADTS file
    /// keeps them, so they are dropped before encoding again; otherwise the track
    /// would slip against the system track by this much on every pass.
    static let encoderDelayFrames = 2112
    static let rawCopyName = "mic.raw.aac"

    /// Level the loudest speech passages are raised to (95th percentile of the
    /// 50 ms frame levels), -20 dBFS.
    static let targetLevel: Float = 0.1
    /// Largest boost, +24 dB.
    static let maximumGain: Float = 15.85
    /// Tracks whose loud passages stay under -60 dBFS hold no speech to raise.
    static let silenceLevel: Float = 0.001

    /// Cleans `mic` in place with `system` as the bleed reference.
    @discardableResult
    static func clean(
        mic: URL, system: URL, encoder: EncoderSettings = .voice, keepRaw: Bool = false
    ) throws -> Summary {
        let started = Date()
        var summary = Summary()
        let gain = try measureGain(of: mic, encoder: encoder)
        summary.gainDB = Double(20 * log10(gain))

        let temporary = mic.deletingLastPathComponent().appendingPathComponent("mic.cleaning.aac")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let micReader = try TrackReader(url: mic, format: encoder.processingFormat)
            let systemReader = try? TrackReader(url: system, format: encoder.processingFormat)
            let writer = try TrackWriter(url: temporary, encoder: encoder, skipping: encoderDelayFrames, gain: gain)
            try process(mic: micReader, system: systemReader, writer: writer, rate: encoder.sampleRate, summary: &summary)
        }

        summary.seconds = Date().timeIntervalSince(started)
        if summary.cleanedBlocks > 0 || gain > 1 {
            if keepRaw {
                let raw = mic.deletingLastPathComponent().appendingPathComponent(rawCopyName)
                try? FileManager.default.removeItem(at: raw)
                try FileManager.default.copyItem(at: mic, to: raw)
            }
            _ = try FileManager.default.replaceItemAt(mic, withItemAt: temporary)
            summary.replaced = true
        }
        let delay = summary.delaySeconds ?? -1
        logger.notice("Mic track pass: blocks=\(summary.blocks, privacy: .public) cleaned=\(summary.cleanedBlocks, privacy: .public) delay=\(delay, privacy: .public)s gain=\(summary.gainDB, privacy: .public)dB replaced=\(summary.replaced, privacy: .public) took=\(summary.seconds, privacy: .public)s")
        return summary
    }

    // MARK: - Block loop

    /// Runs half-overlapping blocks through the bleed remover and cross-fades
    /// their outputs, reading and writing as it goes so memory stays bounded.
    private static func process(
        mic: TrackReader, system: TrackReader?, writer: TrackWriter, rate: Double, summary: inout Summary
    ) throws {
        let remover = MicBleedRemover()
        let block = Int(blockSeconds * rate)
        let hop = block / 2
        var micBuffer: [Float] = []
        var refBuffer = [Float](repeating: 0, count: MicBleedRemover.referenceLead)
        var previousTail: [Float]?
        var delays: [Double] = []
        var reachedEnd = false

        while true {
            while micBuffer.count < block, !reachedEnd {
                let chunk = try mic.read(block - micBuffer.count)
                if chunk.isEmpty {
                    reachedEnd = true
                } else {
                    micBuffer += chunk
                    refBuffer += try system?.readPadded(chunk.count) ?? [Float](repeating: 0, count: chunk.count)
                }
            }
            if micBuffer.isEmpty { break }
            if let tail = previousTail, micBuffer.count <= tail.count {
                try writer.write(Array(tail[0 ..< micBuffer.count]))
                break
            }

            let result = remover.clean(mic: micBuffer, reference: refBuffer, sampleRate: rate)
            summary.blocks += 1
            summary.correlations.append(result.correlation)
            summary.explained.append(result.explained)
            if result.cleaned { summary.cleanedBlocks += 1 }
            if let delay = result.delaySeconds { delays.append(delay) }
            var output = result.samples
            if let tail = previousTail { crossFade(from: tail, into: &output) }

            if reachedEnd {
                try writer.write(output)
                break
            }
            try writer.write(Array(output[0 ..< hop]))
            previousTail = Array(output[hop...])
            micBuffer.removeFirst(hop)
            refBuffer.removeFirst(hop)
        }
        summary.delaySeconds = delays.isEmpty ? nil : delays.sorted()[delays.count / 2]
    }

    /// Fades linearly from `tail` (end of the previous block) into the start of `output`.
    static func crossFade(from tail: [Float], into output: inout [Float]) {
        let count = min(tail.count, output.count)
        for index in 0 ..< count {
            let weight = (Float(index) + 0.5) / Float(count)
            output[index] = tail[index] * (1 - weight) + output[index] * weight
        }
    }

    // MARK: - Level

    /// The gain that raises the loud passages of the track to `targetLevel`.
    /// Never below 1, never so high that the track's peak would clip.
    static func measureGain(of url: URL, encoder: EncoderSettings) throws -> Float {
        let reader = try TrackReader(url: url, format: encoder.processingFormat)
        let frame = Int(encoder.sampleRate / 20)
        var levels: [Float] = []
        var peak: Float = 0
        while true {
            let chunk = try reader.read(frame * 200)
            if chunk.isEmpty { break }
            peak = max(peak, vDSP.maximumMagnitude(chunk))
            var start = 0
            while start + frame <= chunk.count {
                levels.append(vDSP.rootMeanSquare(chunk[start ..< start + frame]))
                start += frame
            }
        }
        return gain(levels: levels, peak: peak)
    }

    /// Pure part of `measureGain`: the gain for a set of frame levels and the peak.
    static func gain(levels: [Float], peak: Float) -> Float {
        guard !levels.isEmpty, peak > 0 else { return 1 }
        let loud = levels.sorted()[min(levels.count - 1, levels.count * 95 / 100)]
        guard loud >= silenceLevel else { return 1 }
        let gain = min(targetLevel / loud, maximumGain, 0.9 / peak)
        // Less than 1 dB is not worth encoding the track again.
        return gain < 1.12 ? 1 : gain
    }
}

/// Decodes an audio file into mono float chunks.
final class TrackReader {
    private var file: ExtAudioFileRef?

    /// Opens `url` and asks for samples in `format`.
    init(url: URL, format: AVAudioFormat) throws {
        var reference: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(url as CFURL, &reference)
        guard openStatus == noErr, let reference else {
            throw CaptureError.micEngineFailed("Could not open \(url.lastPathComponent) (OSStatus \(openStatus))")
        }
        file = reference
        var client = format.streamDescription.pointee
        let formatStatus = ExtAudioFileSetProperty(
            reference, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client
        )
        guard formatStatus == noErr else {
            throw CaptureError.micEngineFailed("Could not decode \(url.lastPathComponent) (OSStatus \(formatStatus))")
        }
    }

    deinit {
        if let file { ExtAudioFileDispose(file) }
    }

    /// Up to `count` samples; fewer at the end of the file, none after it.
    func read(_ count: Int) throws -> [Float] {
        guard let file, count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            var frames = UInt32(count - filled)
            let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: frames * UInt32(MemoryLayout<Float>.size),
                        mData: bytes.baseAddress?.advanced(by: filled * MemoryLayout<Float>.size)
                    )
                )
                return ExtAudioFileRead(file, &frames, &list)
            }
            guard status == noErr else {
                throw CaptureError.micEngineFailed("Reading audio failed (OSStatus \(status))")
            }
            if frames == 0 { break }
            filled += Int(frames)
        }
        samples.removeLast(count - filled)
        return samples
    }

    /// Exactly `count` samples, zero-filled past the end of the file.
    func readPadded(_ count: Int) throws -> [Float] {
        let samples = try read(count)
        return samples + [Float](repeating: 0, count: count - samples.count)
    }
}

/// Encodes mono float chunks to an audio file, after an optional gain.
final class TrackWriter {
    private var file: ExtAudioFileRef?
    private var remainingSkip: Int
    private let gain: Float

    /// Creates `url` with the recording format. The first `skipping` samples
    /// written are dropped; the rest are scaled by `gain` and clipped.
    init(url: URL, encoder: EncoderSettings, skipping: Int, gain: Float) throws {
        file = try VPIOFileHelper.createExtAudioFile(
            url: url, encoder: encoder, processingFormat: encoder.processingFormat
        )
        remainingSkip = skipping
        self.gain = gain
    }

    deinit {
        if let file { ExtAudioFileDispose(file) }
    }

    /// Appends `samples`.
    func write(_ samples: [Float]) throws {
        guard let file else { return }
        let dropped = min(remainingSkip, samples.count)
        remainingSkip -= dropped
        var output = Array(samples[dropped...])
        guard !output.isEmpty else { return }
        if gain != 1 {
            output = vDSP.clip(vDSP.multiply(gain, output), to: -1 ... 1)
        }
        let status = output.withUnsafeMutableBytes { bytes -> OSStatus in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
                )
            )
            return ExtAudioFileWrite(file, UInt32(bytes.count / MemoryLayout<Float>.size), &list)
        }
        guard status == noErr else {
            throw CaptureError.micEngineFailed("Writing the cleaned microphone track failed (OSStatus \(status))")
        }
    }
}
