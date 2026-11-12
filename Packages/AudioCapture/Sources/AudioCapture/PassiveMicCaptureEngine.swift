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
/// This engine opens the chosen microphone for input and nothing else. It never
/// reads or changes an output device, a sample rate or the default input, so a
/// running call cannot notice it. Echo and level are handled after the recording
/// by `MicTrackCleaner`.
final class PassiveMicCaptureEngine: CaptureEngine, @unchecked Sendable {
    private let encoder: EncoderSettings

    /// Owned by engineQueue; each start gets a separate file and callback lifetime.
    private var session: MicCaptureSession?
    private let capturingFlag = Atomic<Bool>(false)
    private let engineQueue = DispatchQueue(
        label: "net.scosman.biscotti.mic.passive-engine", qos: .userInitiated
    )
    private var isTearingDown = false
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?

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
                        installConfigChangeObserver()
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
                teardownEngine()
                do {
                    try buildAndStartEngine()
                    cont.resume()
                } catch {
                    logger.error("Mic reconnect failed: \(error.localizedDescription, privacy: .public)")
                    shutDown()
                    cont.resume(throwing: CaptureError.micEngineFailed(error.localizedDescription))
                }
            }
        }
    }

    deinit {
        removeConfigChangeObserver()
        teardownEngine()
        closeSession()
    }

    // MARK: - Engine lifecycle (engineQueue)

    /// Builds an input-only engine on the chosen microphone and starts it.
    private func buildAndStartEngine() throws {
        guard capturingFlag.load(ordering: .acquiring) else { return }
        guard let session else {
            throw CaptureError.micEngineFailed("No microphone recording session is open.")
        }

        let newEngine = AVAudioEngine()
        engine = newEngine // store early so teardownEngine() works on failure
        let input = newEngine.inputNode
        let inputID = resolveInputDevice()
        if let inputID, inputID != CoreAudioHelpers.defaultInputDeviceID() {
            selectInputDevice(inputID, on: input)
        }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.micEngineFailed("The microphone has no usable audio format.")
        }
        let outputID = CoreAudioHelpers.defaultOutputDeviceID() ?? 0
        let outputBusy = CoreAudioHelpers.isRunningSomewhere(outputID)
        let outputRate = CoreAudioHelpers.nominalSampleRate(for: outputID) ?? 0

        // Only the input node is tapped; the engine has no output node in its
        // graph, so no output device is opened.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil, block: session.makeTapHandler())
        newEngine.prepare()
        try newEngine.start()

        let name = inputID.flatMap { CoreAudioHelpers.deviceName(for: $0) } ?? "unknown"
        logger.notice("Passive mic setup: input=\(name) id=\(inputID ?? 0, privacy: .public) rate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public); default output id=\(outputID, privacy: .public) rate=\(outputRate, privacy: .public) busy=\(outputBusy, privacy: .public) left untouched")
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

    /// Points the input unit at `deviceID` before it starts, so a different
    /// default input (for example Bluetooth headphones) is never opened.
    private func selectInputDevice(_ deviceID: AudioObjectID, on input: AVAudioInputNode) {
        guard let unit = input.audioUnit else {
            logger.error("Mic input unit missing; recording from the system default instead of device \(deviceID, privacy: .public)")
            return
        }
        var objectID = deviceID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &objectID, UInt32(MemoryLayout<AudioObjectID>.size)
        )
        if status != noErr {
            logger.error("Mic input could not be set to device \(deviceID, privacy: .public) (status \(status, privacy: .public)); recording from the system default")
        }
    }

    private func teardownEngine() {
        session?.invalidateTap()
        guard let current = engine else { return }
        current.inputNode.removeTap(onBus: 0)
        if current.isRunning { current.stop() }
        engine = nil
    }

    /// Ends the capture for good: observer, engine, file and the capturing flag.
    private func shutDown() {
        removeConfigChangeObserver()
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

    // MARK: - Config-change observer

    private func installConfigChangeObserver() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] notification in
            guard let source = notification.object as? AVAudioEngine else { return }
            self?.handleConfigurationChange(engineID: ObjectIdentifier(source))
        }
    }

    private func removeConfigChangeObserver() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
    }

    /// The microphone changed format or went away: rebuild on the current choice.
    /// A notification while the engine still runs and has not delivered audio is
    /// the start-up settling of the device and is left alone.
    private func handleConfigurationChange(engineID: ObjectIdentifier) {
        engineQueue.async { [weak self] in
            guard let self, !isTearingDown, capturingFlag.load(ordering: .acquiring),
                  let engine, ObjectIdentifier(engine) == engineID else { return }
            let delivered = session?.hasDeliveredBuffer ?? false
            let running = engine.isRunning
            logger.notice("Passive mic config change: running=\(running, privacy: .public), bufferDelivered=\(delivered, privacy: .public)")
            if !delivered, running { return }

            teardownEngine()
            do {
                try buildAndStartEngine()
            } catch {
                logger.error("Passive mic recovery failed: \(error.localizedDescription, privacy: .public)")
                shutDown()
                let handler = onUnrecoverableError
                DispatchQueue.global().async { handler?(error) }
            }
        }
    }

    var onUnrecoverableError: (@Sendable (Error) -> Void)?
}
