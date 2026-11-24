import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "PassiveMicCapture")

/// Pavarotti: microphone capture that only listens.
///
/// Upstream records the microphone through Apple's voice processing
/// (`LiveMicCaptureEngine`). That unit is a duplex device: it needs an output
/// next to the microphone, builds a system aggregate of both, and takes part in
/// the echo cancellation of whatever call is running. On real calls this changed
/// what the user and the other side heard: an output reclocked mid-call, Bluetooth
/// headphones pushed into headset mode, the other side hearing themselves, and
/// bleed left in the recording whenever the unit's output was not the device the
/// call played through.
///
/// This engine reads the chosen microphone straight from the audio HAL (an IO
/// proc on that one device) and touches nothing else: no output device, no
/// sample rate, and never the default input. `AVAudioEngine` is not used: its
/// input node belongs to the default input, and with Bluetooth headphones as
/// default it opened their microphone (headset mode) and then failed to start on
/// the chosen 48 kHz microphone (-10868, 2026-11-23/24). Echo and level are
/// handled after the recording by `MicTrackCleaner`.
final class PassiveMicCaptureEngine: CaptureEngine, @unchecked Sendable {
    private let encoder: EncoderSettings

    /// Owned by engineQueue; each start gets a separate file and callback lifetime.
    private var session: MicCaptureSession?
    private let capturingFlag = Atomic<Bool>(false)
    private let engineQueue = DispatchQueue(
        label: "net.scosman.biscotti.mic.passive-engine", qos: .userInitiated
    )
    private var isTearingDown = false
    /// The device being read and its IO proc; `nil` while no capture runs.
    private var running: (device: AudioObjectID, proc: AudioDeviceIOProcID)?
    private var deviceListeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    /// Counts engine builds and teardowns, so a retry scheduled for an older
    /// state does nothing. Owned by engineQueue.
    private var generation = 0

    /// Delays between attempts to bring the input back after a failed rebuild.
    /// After the last one the engine keeps trying at that pace until `stop()`.
    static let retryDelays: [Double] = [0.3, 0.6, 1.2, 2.5, 5]

    /// The Core Audio UID of the microphone to record from, read at every engine
    /// build; `nil` or a disconnected device means the system default.
    private let preferredInputUID: @Sendable () -> String?

    private let _micWriteError = Mutex<OSStatus?>(nil)

    /// Non-nil if writing the microphone file failed during the last session.
    var writeError: OSStatus? {
        _micWriteError.withLock { $0 }
    }

    private let firstBufferCallback = Mutex<(@Sendable (Double) -> Void)?>(nil)

    /// Registers the first-buffer callback for the next capture attempt.
    func setOnFirstBuffer(_ callback: (@Sendable (Double) -> Void)?) {
        firstBufferCallback.withLock { $0 = callback }
    }

    /// Configures the file encoding and the microphone preference.
    init(encoder: EncoderSettings = .voice, preferredInputUID: @escaping @Sendable () -> String? = { nil }) {
        self.encoder = encoder
        self.preferredInputUID = preferredInputUID
    }

    // MARK: - CaptureEngine conformance

    /// Opens a fresh recording session and starts listening.
    func start(writingTo url: URL) async throws {
        guard !capturingFlag.load(ordering: .acquiring) else { return }
        let callback = firstBufferCallback.withLock { $0 }
        _micWriteError.withLock { $0 = nil }
        capturingFlag.store(true, ordering: .releasing)

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                engineQueue.async { [self] in
                    isTearingDown = false
                    do {
                        session = try MicCaptureSession(url: url, encoder: encoder, onFirstBuffer: callback)
                        try buildAndStartEngine()
                        cont.resume()
                    } catch {
                        shutDown()
                        cont.resume(throwing: error)
                    }
                }
            }
        } catch {
            throw CaptureError.micEngineFailed(error.localizedDescription)
        }
    }

    /// Stops listening and finalizes the session file.
    func stop() async {
        guard capturingFlag.load(ordering: .acquiring) else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            engineQueue.async { [self] in
                isTearingDown = true
                shutDown()
                cont.resume()
            }
        }
    }

    /// Rebuilds the input on the current microphone, keeping the session file.
    func reconnect() async throws {
        guard capturingFlag.load(ordering: .acquiring) else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            engineQueue.async { [self] in
                guard !isTearingDown else {
                    cont.resume()
                    return
                }
                rebuildOrRetry(reason: "reconnect")
                cont.resume()
            }
        }
    }

    /// Rebuilds the input. A failure never ends the recording: the file stays
    /// open, the gap is filled with silence once audio returns, and the build
    /// is tried again until it works or the recording stops.
    private func rebuildOrRetry(reason: String, attempt: Int = 0) {
        teardownEngine()
        do {
            try buildAndStartEngine()
            if attempt > 0 {
                logger.notice("Passive mic back after \(attempt, privacy: .public) retries (\(reason, privacy: .public))")
            }
        } catch {
            teardownEngine()
            let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
            logger.error("Passive mic rebuild failed (\(reason, privacy: .public), attempt \(attempt + 1, privacy: .public)): \(error.localizedDescription, privacy: .public); retrying in \(delay, privacy: .public)s")
            let expected = generation
            engineQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !isTearingDown, capturingFlag.load(ordering: .acquiring),
                      generation == expected, running == nil else { return }
                rebuildOrRetry(reason: reason, attempt: attempt + 1)
            }
        }
    }

    deinit {
        teardownEngine()
        closeSession()
    }

    // MARK: - Capture lifecycle (engineQueue)

    /// Starts an IO proc on the chosen microphone.
    private func buildAndStartEngine() throws {
        guard capturingFlag.load(ordering: .acquiring) else { return }
        guard let session else {
            throw CaptureError.micEngineFailed("No microphone recording session is open.")
        }
        guard let deviceID = resolveInputDevice() else {
            throw CaptureError.micEngineFailed("No microphone is connected.")
        }
        guard let stream = CoreAudioHelpers.streamFormat(for: deviceID, scope: kAudioObjectPropertyScopeInput),
              stream.mSampleRate > 0, stream.mChannelsPerFrame > 0,
              stream.mFormatID == kAudioFormatLinearPCM,
              stream.mFormatFlags & kAudioFormatFlagIsFloat != 0, stream.mBitsPerChannel == 32,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: stream.mSampleRate, channels: 1, interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.maxFramesPerCycle)
        else {
            throw CaptureError.micEngineFailed("The microphone has no usable audio format.")
        }

        let handler = session.makeTapHandler()
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, input, inputTime, _, _ in
            Self.deliver(input, at: inputTime.pointee.mHostTime, through: buffer, to: handler)
        }
        guard status == noErr, let procID else {
            throw CaptureError.micEngineFailed("Could not attach to the microphone (OSStatus \(status)).")
        }
        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            throw CaptureError.micEngineFailed("Could not start the microphone (OSStatus \(startStatus)).")
        }
        running = (deviceID, procID)
        generation += 1
        installDeviceListeners(on: deviceID)
        logSetup(deviceID: deviceID, stream: stream)
    }

    /// Largest IO cycle accepted; the HAL's are a few hundred to a few thousand frames.
    private static let maxFramesPerCycle: AVAudioFrameCount = 16384

    /// IO thread: copies channel 0 of the first input stream into `buffer` and
    /// hands it to the session, which copies it on before returning.
    private static func deliver(
        _ input: UnsafePointer<AudioBufferList>, at hostTime: UInt64,
        through buffer: AVAudioPCMBuffer, to handler: (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData, first.mNumberChannels > 0,
              let target = buffer.floatChannelData?[0]
        else { return }
        let channels = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0, frames <= Int(buffer.frameCapacity) else { return }
        let source = data.assumingMemoryBound(to: Float.self)
        for frame in 0 ..< frames {
            target[frame] = source[frame * channels]
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        handler(buffer, AVAudioTime(hostTime: hostTime))
    }

    private func logSetup(deviceID: AudioObjectID, stream: AudioStreamBasicDescription) {
        let name = CoreAudioHelpers.deviceName(for: deviceID) ?? "unknown"
        let defaultInput = CoreAudioHelpers.defaultInputDeviceID() ?? 0
        let defaultInputRate = CoreAudioHelpers.nominalSampleRate(for: defaultInput) ?? 0
        let outputID = CoreAudioHelpers.defaultOutputDeviceID() ?? 0
        let outputRate = CoreAudioHelpers.nominalSampleRate(for: outputID) ?? 0
        logger.notice("Passive mic setup: input=\(name) id=\(deviceID, privacy: .public) rate=\(stream.mSampleRate, privacy: .public) channels=\(stream.mChannelsPerFrame, privacy: .public); default input id=\(defaultInput, privacy: .public) rate=\(defaultInputRate, privacy: .public); default output id=\(outputID, privacy: .public) rate=\(outputRate, privacy: .public); neither touched")
    }

    /// The preferred microphone when it is connected, otherwise the system default.
    private func resolveInputDevice() -> AudioObjectID? {
        if let uid = preferredInputUID() {
            if let id = CoreAudioHelpers.deviceID(forUID: uid) {
                return id
            }
            logger.notice("Preferred microphone \(uid, privacy: .public) is not connected; recording from the system default")
        }
        return CoreAudioHelpers.defaultInputDeviceID()
    }

    private func teardownEngine() {
        session?.invalidateTap()
        guard let current = running else { return }
        removeDeviceListeners(from: current.device)
        AudioDeviceStop(current.device, current.proc)
        AudioDeviceDestroyIOProcID(current.device, current.proc)
        running = nil
        generation += 1
    }

    /// Ends the capture for good: device, file and the capturing flag.
    private func shutDown() {
        teardownEngine()
        closeSession()
        capturingFlag.store(false, ordering: .releasing)
    }

    private func closeSession() {
        session?.close()
        if let sessionError = session?.writeError {
            _micWriteError.withLock { $0 = $0 ?? sessionError }
        }
        session = nil
    }

    // MARK: - Device changes

    /// The microphone changing its format or disappearing rebuilds the capture
    /// (on the default input when the chosen microphone is gone).
    private func installDeviceListeners(on deviceID: AudioObjectID) {
        let selectors = [
            kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyStreamFormat, kAudioDevicePropertyDeviceIsAlive
        ]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: selector == kAudioDevicePropertyStreamFormat ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let expected = generation
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, !isTearingDown, capturingFlag.load(ordering: .acquiring),
                      generation == expected else { return }
                logger.notice("Passive mic device change (selector \(selector, privacy: .public)) on device \(deviceID, privacy: .public); rebuilding")
                rebuildOrRetry(reason: "device change")
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, engineQueue, block) == noErr {
                deviceListeners.append((address, block))
            }
        }
    }

    private func removeDeviceListeners(from deviceID: AudioObjectID) {
        for listener in deviceListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, engineQueue, listener.block)
        }
        deviceListeners.removeAll()
    }
}
