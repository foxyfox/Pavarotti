import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os
import Synchronization

/// Records a microphone into memory for one dictation.
///
/// Pavarotti: records through a Core Audio input unit bound to the chosen device, or to
/// the system default when none is chosen or it is not connected. Bluetooth headphones
/// like AirPods switch to their headset profile when their microphone opens, which
/// changes their sample rate; the recorder then keeps what it has and records on in the
/// new rate. ``stop()`` resamples to 16 kHz.
public final class MicrophoneRecorder: DictationAudioSource, @unchecked Sendable {
    private static let logger = Logger(subsystem: "de.foxagon.pavarotti", category: "Dictation")
    /// How often one dictation restarts after a rate change before giving up.
    private static let maximumRestarts = 3

    private struct Capture {
        var audio = RecordedAudio(sampleRate: 0)
        var onFirstAudio: (@Sendable () -> Void)?
        var isActive = false
        var level: Float = 0
    }

    private let capture = Mutex(Capture())
    /// Only touched from the caller's thread (the main actor), like the ones below.
    private var input: InputUnit?
    private var device: CoreAudioInputDevice?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var restarts = 0

    public init() {}

    deinit {
        finishCapture()
    }

    public func start(microphoneID: String?, onFirstAudio: @escaping @Sendable () -> Void) throws {
        finishCapture()
        let device = try Self.inputDevice(preferring: microphoneID)
        let input = try openInput(on: device)
        capture.withLock { state in
            state = Capture(audio: RecordedAudio(sampleRate: input.sampleRate), onFirstAudio: onFirstAudio, isActive: true)
            state.audio.samples.reserveCapacity(Int(input.sampleRate) * 30)
        }
        self.input = input
        self.device = device
        restarts = 0
        // Before starting: opening AirPods' microphone can switch their rate right away.
        listenForRateChanges(of: device.objectID)
        do {
            try input.start()
        } catch {
            finishCapture()
            throw error
        }
        Self.logger.notice(
            "Dictation records from \(device.device.name, privacy: .public) at \(input.sampleRate, privacy: .public) Hz"
        )
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

    /// The connected device with the UID `uid`, else the system default input.
    private static func inputDevice(preferring uid: String?) throws -> CoreAudioInputDevice {
        if let uid {
            if let device = CoreAudioInputDevices.device(withUID: uid) {
                return device
            }
            logger.warning("Microphone \(uid, privacy: .public) is not connected; recording from the system default")
        }
        guard let device = CoreAudioInputDevices.defaultInput() else {
            throw DictationError.microphoneUnavailable("No input device is available.")
        }
        return device
    }

    private func openInput(on device: CoreAudioInputDevice) throws -> InputUnit {
        try InputUnit.open(device: device.objectID) { [self] samples in
            append(samples)
        }
    }

    /// Restarts on the main thread when the device changes its rate.
    private func listenForRateChanges(of deviceID: AudioObjectID) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.restartAfterRateChange(deviceID: deviceID)
        }
        var address = DeviceSampleRate.address
        guard AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, listener) == noErr else { return }
        rateListener = listener
    }

    private func stopListeningForRateChanges() {
        if let rateListener, let device {
            var address = DeviceSampleRate.address
            AudioObjectRemovePropertyListenerBlock(device.objectID, &address, .main, rateListener)
        }
        rateListener = nil
    }

    /// Keeps what was recorded and records on from the same device at its new rate.
    private func restartAfterRateChange(deviceID: AudioObjectID) {
        let isActive = capture.withLock { $0.isActive }
        guard isActive, let input, let device, device.objectID == deviceID,
              let rate = DeviceSampleRate.current(of: deviceID), abs(rate - input.sampleRate) > 0.5
        else { return }
        guard restarts < Self.maximumRestarts else {
            Self.logger.error("The microphone keeps changing its rate; recording on at \(input.sampleRate, privacy: .public) Hz")
            return
        }
        restarts += 1
        input.close()
        self.input = nil
        do {
            let next = try openInput(on: device)
            capture.withLock { $0.audio.switchFormat(to: next.sampleRate) }
            do {
                try next.start()
            } catch {
                next.close()
                throw error
            }
            self.input = next
            Self.logger.notice("The microphone changed to \(next.sampleRate, privacy: .public) Hz; recording on")
        } catch {
            Self.logger.error("Could not record on after a microphone change: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    private func finishCapture() -> Capture {
        stopListeningForRateChanges()
        input?.close()
        input = nil
        device = nil
        return capture.withLock { state in
            let finished = state
            state = Capture()
            return finished
        }
    }

    private func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        let chunk = Array(samples)
        let level = DictationAudio.meterLevel(rms: DictationAudio.rms(chunk))
        let callback = capture.withLock { state -> (@Sendable () -> Void)? in
            guard state.isActive else { return nil }
            state.audio.samples.append(contentsOf: chunk)
            state.level = level
            let pending = state.onFirstAudio
            state.onFirstAudio = nil
            return pending
        }
        callback?()
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
