import CohereTranscribe
import Foundation

/// Errors dictation reports to the user.
public enum DictationError: Error, Equatable, LocalizedError {
    case microphoneUnavailable(String)
    case modelNotInstalled
    case unknownModel(String)
    case unsupportedSoundFile(String)

    public var errorDescription: String? {
        switch self {
        case let .microphoneUnavailable(reason):
            "The microphone could not be started. \(reason)"
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
    /// Starts recording. `onFirstAudio` runs once, on any thread, when audio arrives,
    /// which is the moment the microphone is really listening.
    func start(onFirstAudio: @escaping @Sendable () -> Void) throws
    /// Stops recording and returns mono samples at ``DictationAudio/sampleRate``.
    func stop() -> [Float]
    /// Stops recording and drops the audio.
    func cancel()
}

/// Constants shared by recorder and engine.
public enum DictationAudio {
    /// Cohere Transcribe works on 16 kHz audio.
    public static let sampleRate = 16000
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

    public init(
        audio: any DictationAudioSource,
        engine: any DictationTranscribing,
        inserter: any TextInserting,
        sounds: any SoundCuePlaying,
        ducker: any OutputDucking,
        accessibility: any AccessibilityTrust,
        soundLibrary: SoundLibrary
    ) {
        self.audio = audio
        self.engine = engine
        self.inserter = inserter
        self.sounds = sounds
        self.ducker = ducker
        self.accessibility = accessibility
        self.soundLibrary = soundLibrary
    }
}
