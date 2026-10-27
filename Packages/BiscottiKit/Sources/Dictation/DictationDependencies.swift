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
            "The microphone could not be started. \(reason)"
        case .microphoneDenied:
            "Pavarotti may not use the microphone. Allow it in System Settings \u{2192} Privacy & Security \u{2192} Microphone."
        case .silentMicrophone:
            "The microphone recorded only silence. Choose another one in Settings \u{2192} Dictation."
        case .nothingHeard:
            "Nothing was heard. Check the microphone in Settings \u{2192} Dictation."
        case .modelNotInstalled:
            "Install the Cohere model in Settings \u{2192} Dictation first."
        case let .unknownModel(id):
            "Unknown dictation model \(id)."
        case let .unsupportedSoundFile(name):
            "\(name) is not a sound file Pavarotti can play (WAV, AIFF, MP3, M4A or CAF)."
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
}

/// Turns recorded samples into text.
public protocol DictationTranscribing: Sendable {
    func isInstalled(modelID: String) -> Bool
    func install(modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws
    /// Loads the model so the next transcription is fast.
    func prepare(modelID: String) async throws
    func transcribe(
        samples: [Float],
        sampleRate: Int,
        language: TranscriptionLanguage,
        modelID: String
    ) async throws -> String
    /// Unloads the model.
    func shutdown() async
}

/// How text reached the focused app.
public enum TextInsertionResult: Equatable, Sendable {
    case pasted
    /// The text is on the clipboard, but could not be pasted (no Accessibility access).
    case copiedOnly
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
        microphones: any MicrophoneProviding
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
    }
}
