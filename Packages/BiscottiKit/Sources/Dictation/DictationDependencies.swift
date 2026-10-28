import CohereTranscribe
import Foundation

/// Errors dictation reports to the user.
public enum DictationError: Error, Equatable, LocalizedError {
    case microphoneUnavailable(String)
    case microphoneDenied
    case silentMicrophone
    case nothingHeard
    case modelNotInstalled
    case unknownModel(String)
    case unsupportedSoundFile(String)

    public var errorDescription: String? {
        switch self {
        case let .microphoneUnavailable(reason):
            String(localized: "The microphone could not be started. \(reason)")
        case .microphoneDenied:
            String(localized: "Pavarotti may not use the microphone. Allow it in System Settings \u{2192} Privacy & Security \u{2192} Microphone.")
        case .silentMicrophone:
            String(localized: "The microphone recorded only silence. Choose another one in Settings \u{2192} Dictation.")
        case .nothingHeard:
            String(localized: "Nothing was heard. Check the microphone in Settings \u{2192} Dictation.")
        case .modelNotInstalled:
            String(localized: "Install the Cohere model in Settings \u{2192} Dictation first.")
        case let .unknownModel(id):
            String(localized: "Unknown dictation model \(id).")
        case let .unsupportedSoundFile(name):
            String(localized: "\(name) is not a sound file Pavarotti can play (WAV, AIFF, MP3, M4A or CAF).")
        }
    }
}

/// Records the microphone for one dictation.
public protocol DictationAudioSource: AnyObject {
    /// Starts recording from the input device with the Core Audio UID `microphoneID`, or from
    /// the system default when it is `nil` or not connected. `onFirstAudio` runs once, on any
    /// thread, when audio arrives, which is the moment the microphone is really listening.
    func start(microphoneID: String?, onFirstAudio: @escaping @Sendable () -> Void) throws
    /// Stops recording and returns mono samples at ``DictationAudio/sampleRate``.
    func stop() -> [Float]
    /// Stops recording and drops the audio.
    func cancel()
    /// The loudness of the latest audio, from 0 to 1 (see ``DictationAudio/meterLevel(rms:)``),
    /// for the recording bubble. 0 while not recording. Read from the main actor.
    var level: Float { get }
}

/// Constants shared by recorder and engine.
public enum DictationAudio {
    /// Cohere Transcribe works on 16 kHz audio.
    public static let sampleRate = 16000
    /// Peak level below which a recording counts as silence (-100 dBFS). A blocked or
    /// switched-off microphone, like a MacBook's with the lid closed, records zeros instead
    /// of failing; a working one is never this quiet.
    public static let silenceThreshold: Float = 0.000_01

    /// Whether `samples` hold nothing but silence.
    public static func isSilent(_ samples: [Float]) -> Bool {
        !samples.contains { abs($0) >= silenceThreshold }
    }

    /// The loudness of a buffer with the root mean square `rms`, for the waveform: 0 at
    /// -55 dBFS and below (a quiet room), 1 at -10 dBFS and above (speaking up close).
    public static func meterLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 55) / 45))
    }

    /// The root mean square of `samples`, 0 for none.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Turns recorded samples into text.
public protocol DictationTranscribing: Sendable {
    func isInstalled(modelID: String) -> Bool
    /// What installing `modelID` still takes.
    func installPlan(modelID: String) -> DictationInstallPlan
    func install(modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws
    /// Loads the model so the next transcription is fast.
    func prepare(modelID: String) async throws
    func transcribe(
        samples: [Float],
        sampleRate: Int,
        language: TranscriptionLanguage,
        modelID: String
    ) async throws -> String
    /// Transcribes with the time of each passage, for files. The default makes the whole
    /// text one passage.
    func transcribeTimed(
        samples: [Float],
        sampleRate: Int,
        language: TranscriptionLanguage,
        modelID: String
    ) async throws -> TimedTranscription
    /// Unloads the model.
    func shutdown() async
    /// Unloads the model once it sat unused this long; `nil` keeps it loaded.
    func setIdleUnload(after limit: Duration?) async
}

public extension DictationTranscribing {
    /// Engines without a costly model ignore it.
    func setIdleUnload(after _: Duration?) async {}

    func transcribeTimed(
        samples: [Float],
        sampleRate: Int,
        language: TranscriptionLanguage,
        modelID: String
    ) async throws -> TimedTranscription {
        let text = try await transcribe(samples: samples, sampleRate: sampleRate, language: language, modelID: modelID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return TimedTranscription(language: nil, passages: []) }
        let end = Double(samples.count) / Double(sampleRate)
        return TimedTranscription(language: nil, passages: [TimedText(start: 0, end: end, text: text)])
    }
}

/// A transcription with the time of each passage.
public struct TimedTranscription: Equatable, Sendable {
    /// ISO 639-1 code of the text, `nil` when the engine does not say.
    public var language: String?
    public var passages: [TimedText]

    public init(language: String?, passages: [TimedText]) {
        self.language = language
        self.passages = passages
    }
}

/// One stretch of speech, in seconds from the start of the audio.
public struct TimedText: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// The words with their times, for meeting transcripts. Empty when the engine does
    /// not time words.
    public var words: [TimedWord]

    public init(start: TimeInterval, end: TimeInterval, text: String, words: [TimedWord] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }

    /// The passage and its words `offset` seconds later.
    func shifted(by offset: TimeInterval) -> TimedText {
        TimedText(
            start: start + offset,
            end: end + offset,
            text: text,
            words: words.map { TimedWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
        )
    }
}

/// One recognized word, in seconds from the start of the audio.
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// What installing a model still takes, for the setup and Settings.
public struct DictationInstallPlan: Equatable, Sendable {
    /// Bytes still to download. Files found in TypeWhisper are copied instead.
    public var downloadBytes: Int64
    /// Whether the model file is copied from TypeWhisper.
    public var copiesModelFromTypeWhisper: Bool

    public init(downloadBytes: Int64, copiesModelFromTypeWhisper: Bool) {
        self.downloadBytes = downloadBytes
        self.copiesModelFromTypeWhisper = copiesModelFromTypeWhisper
    }
}

/// How text reached the focused app.
public enum TextInsertionResult: Equatable, Sendable {
    case pasted
    /// The text is on the clipboard, but could not be pasted (no Accessibility access).
    case copiedOnly
    /// A paste into a remote desktop was not sent.
    case notPasted(PasteSkipReason)
}

/// Why a paste into a remote desktop was not sent.
public enum PasteSkipReason: Equatable, Sendable {
    /// The remote desktop window was no longer in front. The text is on the clipboard.
    case remoteWindowNotInFront
    /// Something else wrote to the clipboard during the clipboard sync, twice.
    case clipboardChanged
    /// The dictation was cancelled during the clipboard sync. The clipboard is as before.
    case cancelled

    /// What the indicator says. `nil` when the user cancelled.
    public var message: String? {
        switch self {
        case .remoteWindowNotInFront:
            "Not pasted: the remote desktop was no longer in front. The text is on the clipboard."
        case .clipboardChanged:
            "Not pasted: the clipboard changed during the sync with the remote desktop. The text is in Recent Dictations."
        case .cancelled:
            nil
        }
    }
}

/// Puts text into the focused app.
@MainActor
public protocol TextInserting: AnyObject {
    func insert(_ text: String, restoringClipboard: Bool) async -> TextInsertionResult
}

/// Plays short sound cues.
@MainActor
public protocol SoundCuePlaying: AnyObject {
    /// Plays `choice` and returns its length in seconds, or `nil` when nothing played.
    @discardableResult
    func play(_ choice: SoundChoice) -> TimeInterval?
}

/// Lowers and restores the volume of other audio.
@MainActor
public protocol OutputDucking: AnyObject {
    /// Lowers the output volume to `level` (0 to 1) of what it is now.
    func duck(to level: Double)
    /// Puts the volume back. Does nothing when not ducked.
    func restore()
}

/// Whether Pavarotti may watch the keyboard and send the paste shortcut.
@MainActor
public protocol AccessibilityTrust: AnyObject {
    var isTrusted: Bool { get }
    /// Shows the system prompt that leads to the Accessibility settings.
    func requestTrust()
}

/// Watches the text field after pasting for corrections the user makes.
@MainActor
public protocol CorrectionWatching: AnyObject {
    /// Starts watching the focused field, into which `inserted` was just pasted.
    /// Ends any earlier watch first.
    func watch(inserted: String, onCorrection: @escaping @MainActor (DetectedCorrection) -> Void)
    /// Ends the watch and reports a correction the user already made.
    func finish()
    /// Ends the watch without reporting anything.
    func stop()
}

/// The parts of dictation that touch the system, bundled for injection.
@MainActor
public struct DictationDependencies {
    public var audio: any DictationAudioSource
    public var engine: any DictationTranscribing
    public var inserter: any TextInserting
    public var sounds: any SoundCuePlaying
    public var ducker: any OutputDucking
    public var accessibility: any AccessibilityTrust
    public var soundLibrary: SoundLibrary
    public var dictionary: PersonalDictionary
    public var corrections: any CorrectionWatching
    public var microphones: any MicrophoneProviding
    public var history: DictationHistory

    public init(
        audio: any DictationAudioSource,
        engine: any DictationTranscribing,
        inserter: any TextInserting,
        sounds: any SoundCuePlaying,
        ducker: any OutputDucking,
        accessibility: any AccessibilityTrust,
        soundLibrary: SoundLibrary,
        dictionary: PersonalDictionary,
        corrections: any CorrectionWatching,
        microphones: any MicrophoneProviding,
        history: DictationHistory
    ) {
        self.audio = audio
        self.engine = engine
        self.inserter = inserter
        self.sounds = sounds
        self.ducker = ducker
        self.accessibility = accessibility
        self.soundLibrary = soundLibrary
        self.dictionary = dictionary
        self.corrections = corrections
        self.microphones = microphones
        self.history = history
    }
}
