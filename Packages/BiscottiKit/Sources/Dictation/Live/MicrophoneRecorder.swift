@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Records the default microphone into memory for one dictation.
///
/// A fresh `AVAudioEngine` per dictation follows the current default input device.
/// The tap mixes to mono at the device rate; ``stop()`` resamples once to 16 kHz.
public final class MicrophoneRecorder: DictationAudioSource, @unchecked Sendable {
    private struct Capture {
        var samples: [Float] = []
        var sampleRate: Double = 0
        var onFirstAudio: (@Sendable () -> Void)?
        var isActive = false
    }

    private let capture = Mutex(Capture())
    /// Only touched from the caller's thread (the main actor).
    private var engine: AVAudioEngine?

    public init() {}

    public func start(onFirstAudio: @escaping @Sendable () -> Void) throws {
        finishCapture()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        guard sampleRate > 0, format.channelCount > 0 else {
            throw DictationError.microphoneUnavailable("No input device is available.")
        }
        capture.withLock { state in
            state = Capture(sampleRate: sampleRate, onFirstAudio: onFirstAudio, isActive: true)
            state.samples.reserveCapacity(Int(sampleRate) * 30)
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: makeTapHandler())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            capture.withLock { $0 = Capture() }
            throw DictationError.microphoneUnavailable(error.localizedDescription)
        }
        self.engine = engine
    }

    public func stop() -> [Float] {
        let finished = finishCapture()
        return AudioResampler.resample(
            finished.samples,
            from: finished.sampleRate,
            to: Double(DictationAudio.sampleRate)
        )
    }

    public func cancel() {
        finishCapture()
    }

    // MARK: - Private

    @discardableResult
    private func finishCapture() -> Capture {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        return capture.withLock { state in
            let finished = state
            state = Capture()
            return finished
        }
    }

    /// Built outside any actor so the audio thread never runs actor-isolated code.
    private func makeTapHandler() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [self] buffer, _ in
            append(buffer)
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        let mono = Self.monoSamples(of: buffer)
        guard !mono.isEmpty else { return }
        let callback = capture.withLock { state -> (@Sendable () -> Void)? in
            guard state.isActive else { return nil }
            state.samples.append(contentsOf: mono)
            let pending = state.onFirstAudio
            state.onFirstAudio = nil
            return pending
        }
        callback?()
    }

    /// Averages all channels of a float buffer, interleaved or not.
    static func monoSamples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return [] }
        let interleaved = buffer.format.isInterleaved
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0 ..< channelCount {
            let base = interleaved ? channels[0] + channel : channels[channel]
            let step = interleaved ? channelCount : 1
            for frame in 0 ..< frames {
                mono[frame] += base[frame * step]
            }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for frame in 0 ..< frames {
                mono[frame] *= scale
            }
        }
        return mono
    }
}

/// One-shot sample rate conversion with `AVAudioConverter`, which filters properly
/// instead of dropping samples.
enum AudioResampler {
    static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0 else { return [] }
        guard abs(sourceRate - targetRate) > 0.5 else { return samples }
        guard let source = monoFormat(sourceRate),
              let target = monoFormat(targetRate),
              let converter = AVAudioConverter(from: source, to: target),
              let input = buffer(with: samples, format: source)
        else {
            return []
        }
        let capacity = AVAudioFrameCount((Double(samples.count) * targetRate / sourceRate).rounded(.up)) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

        var error: NSError?
        nonisolated(unsafe) var hasProvidedInput = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if hasProvidedInput {
                status.pointee = .endOfStream
                return nil
            }
            hasProvidedInput = true
            status.pointee = .haveData
            return input
        }
        let result = converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        guard result != .error, error == nil, let data = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }

    private static func monoFormat(_ sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    private static func buffer(with samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData?[0]
        else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            data[index] = sample
        }
        return buffer
    }
}
