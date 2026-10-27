import CohereTranscribe
import Foundation
import Observation
import os

/// Push-to-talk dictation: listens while the shortcut says so, transcribes with Cohere
/// and pastes the text into the focused app.
///
/// The controller owns the flow and the settings. Everything that touches the system
/// (microphone, server, clipboard, sounds, volume) comes in through
/// ``DictationDependencies``, so the flow is tested with fakes.
@MainActor @Observable
public final class DictationController {
    public enum Phase: Equatable, Sendable {
        case idle
        case listening
        case transcribing
        case failed(String)
    }

    public enum EngineState: Equatable, Sendable {
        case notInstalled
        case installing(Double)
        /// Installed, but the model is not loaded.
        case installed
        case loading
        case ready
        case failed(String)
    }

    /// Recordings shorter than this (seconds) are dropped as accidental presses.
    public static let minimumDuration = 0.3
    /// A dictation stops on its own after this long (seconds).
    public static let maximumDuration = 600.0

    public private(set) var phase = Phase.idle
    public private(set) var engineState = EngineState.notInstalled
    public private(set) var settings: DictationSettings
    public private(set) var isAccessibilityTrusted = false
    public private(set) var lastTranscript: String?
    public private(set) var customSounds: [String] = []
    /// The connected input devices, for the microphone picker. See ``refreshMicrophones()``.
    public internal(set) var microphones: [MicrophoneDevice] = []
    public internal(set) var defaultMicrophone: MicrophoneDevice?
    public internal(set) var microphonePermission = MicrophonePermission.undecided
    /// A short message for the indicator, such as a word the dictionary just learned.
    public internal(set) var notice: String?
    /// While true, shortcut events are ignored (the settings are recording a new shortcut).
    public var isCapturingShortcut = false

    /// Called after the shortcut, the on/off switch or Accessibility access changed,
    /// so the shortcut monitor can follow.
    @ObservationIgnored public var onShortcutConfigurationChange: (@MainActor () -> Void)?

    let dependencies: DictationDependencies
    private let store: DictationSettingsStore
    private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private var gesture: ShortcutGesture
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var duckTask: Task<Void, Never>?
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    @ObservationIgnored private var failureTask: Task<Void, Never>?
    @ObservationIgnored var workTask: Task<Void, Never>?
    @ObservationIgnored private var engineTask: Task<Void, Never>?
    @ObservationIgnored var microphoneRequest: Task<Void, Never>?
    @ObservationIgnored var noticeTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "de.foxagon.pavarotti", category: "Dictation")

    public init(
        store: DictationSettingsStore,
        dependencies: DictationDependencies,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.store = store
        self.dependencies = dependencies
        self.now = now
        let loaded = store.load()
        settings = loaded
        gesture = ShortcutGesture(mode: loaded.mode)
    }

    /// Reads the current state of the system and loads the model when dictation is on.
    public func activate() {
        refreshAccessibility()
        refreshCustomSounds()
        refreshEngineState()
        if settings.isEnabled {
            loadEngine()
        }
    }

    // MARK: - Shortcut

    /// Handles an event from the shortcut monitor.
    public func handle(_ event: ShortcutEvent) {
        guard settings.isEnabled, !isCapturingShortcut else { return }
        switch gesture.handle(event, at: now()) {
        case .start: start()
        case .stop: stop()
        case .cancel: cancel()
        case nil: break
        }
    }

    /// Starts or stops listening, for buttons and menu items.
    public func toggle() {
        if phase == .listening {
            stop()
        } else {
            start()
        }
    }

    // MARK: - Listening

    /// Starts listening. Does nothing while a dictation is already running.
    public func start() {
        guard settings.isEnabled, phase != .listening, phase != .transcribing else { return }
        // The user moved on to the next dictation, so the last one is done.
        dependencies.corrections.finish()
        guard dependencies.engine.isInstalled(modelID: settings.modelID) else {
            gesture.reset()
            fail(DictationError.modelNotInstalled.localizedDescription)
            return
        }
        guard mayRecord() else {
            gesture.reset()
            return
        }
        session += 1
        let current = session
        do {
            try dependencies.audio.start(microphoneID: settings.microphone?.id) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.audioDidStart(session: current)
                }
            }
        } catch {
            gesture.reset()
            fail(error.localizedDescription)
            return
        }
        failureTask?.cancel()
        phase = .listening
        limitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maximumDuration))
            guard let self, !Task.isCancelled, session == current else { return }
            stop()
        }
    }

    /// Stops listening and transcribes what was said.
    public func stop() {
        guard phase == .listening else { return }
        endListening()
        let samples = dependencies.audio.stop()
        gesture.reset()
        let seconds = Double(samples.count) / Double(DictationAudio.sampleRate)
        guard seconds >= Self.minimumDuration else {
            phase = .idle
            return
        }
        guard !DictationAudio.isSilent(samples) else {
            Self.logger.warning("The microphone recorded only silence (\(settings.microphone?.name ?? "system default", privacy: .public))")
            fail(DictationError.silentMicrophone.localizedDescription)
            return
        }
        phase = .transcribing
        let current = session
        let snapshot = settings
        workTask = Task { [weak self] in
            await self?.transcribeAndInsert(samples, snapshot: snapshot, session: current)
        }
    }

    /// Drops the running dictation without inserting anything.
    public func cancel() {
        switch phase {
        case .listening:
            endListening()
            dependencies.audio.cancel()
        case .transcribing:
            workTask?.cancel()
        case .idle, .failed:
            break
        }
        session += 1
        gesture.reset()
        if phase == .listening || phase == .transcribing {
            phase = .idle
        }
    }

    /// The microphone delivered its first audio: play the start sound, then duck.
    func audioDidStart(session started: Int) {
        guard started == session, phase == .listening else { return }
        let soundLength = settings.playsSounds ? dependencies.sounds.play(settings.startSound) : nil
        guard settings.ducksAudio else { return }
        let level = settings.duckingLevel
        let delay = soundLength ?? 0
        guard delay > 0 else {
            dependencies.ducker.duck(to: level)
            return
        }
        // Duck after the start sound, so the cue itself plays at full volume.
        duckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, session == started, phase == .listening else { return }
            dependencies.ducker.duck(to: level)
        }
    }

    private func endListening() {
        limitTask?.cancel()
        limitTask = nil
        duckTask?.cancel()
        duckTask = nil
        dependencies.ducker.restore()
    }

    private func transcribeAndInsert(_ samples: [Float], snapshot: DictationSettings, session started: Int) async {
        do {
            let heard = try await dependencies.engine.transcribe(
                samples: samples,
                sampleRate: DictationAudio.sampleRate,
                language: snapshot.language,
                modelID: snapshot.modelID
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard started == session, !Task.isCancelled else { return }
            if engineState != .ready, snapshot.modelID == settings.modelID {
                engineState = .ready
            }
            guard !heard.isEmpty else {
                fail(DictationError.nothingHeard.localizedDescription)
                return
            }
            let text = dependencies.dictionary.apply(to: heard)
            lastTranscript = text
            // Kept before pasting, so text that does not arrive can be copied again.
            dependencies.history.record(text)
            let result = await dependencies.inserter.insert(text, restoringClipboard: snapshot.restoresClipboard)
            finish(result, text: text, snapshot: snapshot, session: started)
        } catch {
            guard started == session, !(error is CancellationError) else { return }
            Self.logger.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
            fail(error.localizedDescription)
        }
    }

    private func finish(_ result: TextInsertionResult, text: String, snapshot: DictationSettings, session started: Int) {
        switch result {
        case .pasted:
            playCue(snapshot.doneSound)
            phase = .idle
            if snapshot.learnsFromCorrections {
                watchForCorrections(after: text)
            }
        case .copiedOnly:
            fail("Copied to the clipboard. Allow Accessibility access so Pavarotti can paste for you.")
        case let .notPasted(reason):
            if let message = reason.message {
                fail(message)
            } else if started == session {
                // Cancelled during the clipboard sync.
                phase = .idle
            }
        }
    }

    func fail(_ message: String) {
        phase = .failed(message)
        playCue(settings.errorSound)
        failureTask?.cancel()
        failureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, phase == .failed(message) else { return }
            phase = .idle
        }
    }

    private func playCue(_ choice: SoundChoice) {
        guard settings.playsSounds else { return }
        dependencies.sounds.play(choice)
    }

    /// Waits for a running transcription. For tests.
    func waitForWork() async {
        await workTask?.value
    }
}

// MARK: - Settings, engine and permissions

public extension DictationController {
    /// Changes settings, saves them and applies what changed.
    func update(_ change: (inout DictationSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let previous = settings
        settings = next
        store.save(next)
        gesture.mode = next.mode
        if !next.isEnabled {
            cancel()
        }
        if !next.isEnabled || !next.learnsFromCorrections {
            dependencies.corrections.stop()
        }
        if previous.shortcut != next.shortcut || previous.isEnabled != next.isEnabled {
            onShortcutConfigurationChange?()
        }
        if previous.modelID != next.modelID || previous.isEnabled != next.isEnabled {
            engineSettingsChanged()
        }
    }

    /// Downloads the selected model (or copies it from TypeWhisper) and loads it.
    func installModel() {
        let modelID = settings.modelID
        let engine = dependencies.engine
        engineTask?.cancel()
        engineState = .installing(0)
        engineTask = Task { [weak self] in
            do {
                try await engine.install(modelID: modelID) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.installDidProgress(fraction, modelID: modelID)
                    }
                }
                self?.installDidFinish(modelID: modelID, error: nil)
            } catch {
                self?.installDidFinish(modelID: modelID, error: error)
            }
        }
    }

    /// Loads the model again after it failed to start.
    func retryEngine() {
        refreshEngineState()
        if settings.isEnabled {
            loadEngine()
        }
    }

    /// Whether the selected model and the runtime are on disk.
    var isModelInstalled: Bool {
        dependencies.engine.isInstalled(modelID: settings.modelID)
    }

    /// Re-reads whether Pavarotti has Accessibility access.
    func refreshAccessibility() {
        let trusted = dependencies.accessibility.isTrusted
        guard trusted != isAccessibilityTrusted else { return }
        isAccessibilityTrusted = trusted
        onShortcutConfigurationChange?()
    }

    func requestAccessibility() {
        dependencies.accessibility.requestTrust()
        refreshAccessibility()
    }

    /// Plays a sound choice, for the preview buttons in Settings.
    func preview(_ choice: SoundChoice) {
        dependencies.sounds.play(choice)
    }

    /// Copies a sound file into the library and returns its choice.
    func importSound(from url: URL) throws -> SoundChoice {
        let name = try dependencies.soundLibrary.importSound(from: url)
        refreshCustomSounds()
        return .file(name)
    }

    func refreshCustomSounds() {
        customSounds = dependencies.soundLibrary.customSoundNames()
    }

    private func installDidProgress(_ fraction: Double, modelID: String) {
        guard case .installing = engineState, modelID == settings.modelID else { return }
        engineState = .installing(fraction)
    }

    private func installDidFinish(modelID: String, error: (any Error)?) {
        guard !Task.isCancelled, modelID == settings.modelID else { return }
        if let error {
            engineState = .failed(error.localizedDescription)
            return
        }
        engineState = .installed
        if settings.isEnabled {
            loadEngine()
        }
    }

    /// The model or the on/off switch changed. The engine switches models by itself;
    /// turning dictation off unloads the model to free its memory.
    private func engineSettingsChanged() {
        engineTask?.cancel()
        engineTask = nil
        if case .installing = engineState {
            engineState = .notInstalled
        }
        refreshEngineState()
        if settings.isEnabled {
            loadEngine()
        } else {
            let engine = dependencies.engine
            Task { await engine.shutdown() }
        }
    }

    private func refreshEngineState() {
        if case .installing = engineState { return }
        engineState = dependencies.engine.isInstalled(modelID: settings.modelID) ? .installed : .notInstalled
    }

    private func loadEngine() {
        guard engineState == .installed || engineState.isFailure else { return }
        let modelID = settings.modelID
        guard dependencies.engine.isInstalled(modelID: modelID) else {
            engineState = .notInstalled
            return
        }
        engineState = .loading
        let engine = dependencies.engine
        engineTask = Task { [weak self] in
            do {
                try await engine.prepare(modelID: modelID)
                self?.engineDidLoad(modelID: modelID, error: nil)
            } catch {
                self?.engineDidLoad(modelID: modelID, error: error)
            }
        }
    }

    private func engineDidLoad(modelID: String, error: (any Error)?) {
        guard !Task.isCancelled, modelID == settings.modelID else { return }
        if let error {
            engineState = .failed(error.localizedDescription)
        } else {
            engineState = .ready
        }
    }
}

extension DictationController.EngineState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
