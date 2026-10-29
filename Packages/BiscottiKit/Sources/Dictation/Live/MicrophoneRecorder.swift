import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os
import Synchronization

/// Records a microphone into memory for one dictation.
///
/// A fresh `AVAudioEngine` per dictation follows the current default input device, unless
/// a connected device is chosen. The tap mixes to mono at the device rate; ``stop()``
/// resamples once to 16 kHz.
///
/// Pavarotti: a Bluetooth headset like AirPods switches to its headset profile when the
/// microphone opens, so the input changes its sample rate and the engine stops itself.
/// The recorder then keeps what it has and records on in the new format.
public final class MicrophoneRecorder: DictationAudioSource, @unchecked Sendable {
    private static let logger = Logger(subsystem: "de.foxagon.pavarotti", category: "Dictation")
    /// How often one dictation restarts after a format change before giving up.
    private static let maximumRestarts = 3

    private struct Capture {
        var audio = RecordedAudio(sampleRate: 0)
        var onFirstAudio: (@Sendable () -> Void)?
        var isActive = false
        var level: Float = 0
    }

    private let capture = Mutex(Capture())
    /// Only touched from the caller's thread (the main actor), like the two below.
    private var engine: AVAudioEngine?
    private var configurationObserver: (any NSObjectProtocol)?
    private var restarts = 0

    public init() {}

    public func start(microphoneID: String?, onFirstAudio: @escaping @Sendable () -> Void) throws {
        finishCapture()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let microphoneID {
            Self.select(microphoneID, on: input)
        }
        let format = input.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        guard sampleRate > 0, format.channelCount > 0 else {
            throw DictationError.microphoneUnavailable("No input device is available.")
        }
        capture.withLock { state in
            state = Capture(audio: RecordedAudio(sampleRate: sampleRate), onFirstAudio: onFirstAudio, isActive: true)
            state.audio.samples.reserveCapacity(Int(sampleRate) * 30)
        }
        observeConfigurationChanges(of: engine)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: makeTapHandler())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            stopObservingConfigurationChanges()
            capture.withLock { $0 = Capture() }
            throw DictationError.microphoneUnavailable(error.localizedDescription)
        }
        self.engine = engine
        restarts = 0
    }

    public func stop() -> [Float] {
        finishCapture().audio.resampled
    }

    public func cancel() {
        finishCapture()
    }

    public var level: Float {
        capture.withLock { $0.isActive ? $0.level : 0 }
    }

    // MARK: - Private

    /// Points the input node at the device with the UID `uid`, before its format is read.
    /// Keeps the system default when the device is not connected or refuses.
    private static func select(_ uid: String, on input: AVAudioInputNode) {
        guard let device = CoreAudioInputDevices.device(withUID: uid) else {
            logger.warning("Microphone \(uid, privacy: .public) is not connected; recording from the system default")
            return
        }
        guard let unit = input.audioUnit else { return }
        var objectID = device.objectID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &objectID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        if status != noErr {
            logger.error("Could not record from \(device.device.name, privacy: .public) (\(status)); recording from the system default")
        }
    }

    /// Pavarotti: restarts `engine` when it stops itself for a new device format. The
    /// notification comes from an audio thread; the restart runs on the main thread.
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        stopObservingConfigurationChanges()
        let engineID = ObjectIdentifier(engine)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange(engineID: engineID)
        }
    }

    private func stopObservingConfigurationChanges() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
    }

    /// Keeps what was recorded, reads the input's new format and records on in it.
    private func restartAfterConfigurationChange(engineID: ObjectIdentifier) {
        let isActive = capture.withLock { $0.isActive }
        guard isActive, let engine, ObjectIdentifier(engine) == engineID, !engine.isRunning else { return }
        guard restarts < Self.maximumRestarts else {
            Self.logger.error("The microphone keeps changing its format; recording stopped")
            return
        }
        restarts += 1
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Self.logger.error("The microphone has no usable format after a change; recording stopped")
            return
        }
        capture.withLock { $0.audio.switchFormat(to: format.sampleRate) }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: makeTapHandler())
        engine.prepare()
        do {
            try engine.start()
            Self.logger.notice(
                "The microphone changed to \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch; recording on"
            )
        } catch {
            input.removeTap(onBus: 0)
            Self.logger.error("Could not record on after a microphone change: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    private func finishCapture() -> Capture {
        stopObservingConfigurationChanges()
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
        let level = DictationAudio.meterLevel(rms: DictationAudio.rms(mono))
        let callback = capture.withLock { state -> (@Sendable () -> Void)? in
            guard state.isActive else { return nil }
            state.audio.samples.append(contentsOf: mono)
            state.level = level
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

/// Pavarotti: what one dictation recorded. Audio from before the input changed its format
/// is kept at 16 kHz; the current format's audio stays at the device rate until the end.
struct RecordedAudio {
    var earlier: [Float] = []
    var samples: [Float] = []
    var sampleRate: Double

    /// Ends the current part and starts one at `newRate`.
    mutating func switchFormat(to newRate: Double) {
        earlier += Self.resampled(samples, from: sampleRate)
        samples = []
        sampleRate = newRate
    }

    /// All of it, at ``DictationAudio/sampleRate``.
    var resampled: [Float] {
        earlier + Self.resampled(samples, from: sampleRate)
    }

    private static func resampled(_ samples: [Float], from rate: Double) -> [Float] {
        AudioResampler.resample(samples, from: rate, to: Double(DictationAudio.sampleRate))
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
