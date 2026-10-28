import CohereTranscribe
import Foundation

/// A sound cue: none, one of the macOS system sounds, or a file in the sound library.
public enum SoundChoice: Codable, Hashable, Sendable {
    case none
    /// A sound from `/System/Library/Sounds`, by name ("Tink").
    case system(String)
    /// A file in ``SoundLibrary``, by file name.
    case file(String)

    public var displayName: String {
        switch self {
        case .none: "None"
        case let .system(name): name
        case let .file(name): URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        }
    }
}

/// Everything the user can set about dictation. Stored as JSON in user defaults,
/// separate from Biscotti's database, so upstream schema changes never touch it.
public struct DictationSettings: Codable, Equatable, Sendable {
    public var isEnabled = true
    public var shortcut = DictationShortcut.standard
    public var mode = DictationShortcutMode.hybrid
    public var language = TranscriptionLanguage.automatic
    public var modelID = CohereModel.recommended.id
    public var playsSounds = true
    public var startSound = SoundChoice.system("Tink")
    public var doneSound = SoundChoice.system("Pop")
    public var errorSound = SoundChoice.system("Basso")
    /// Lowers the volume of other audio while listening.
    public var ducksAudio = false
    /// The share of the original volume other audio keeps while ducked (0 to 1).
    public var duckingLevel = 0.2
    /// Puts the previous clipboard contents back after pasting.
    public var restoresClipboard = true
    /// Adds words the user fixes after pasting to the dictionary.
    public var learnsFromCorrections = true
    /// The input device to record from. `nil` follows the system's default input.
    public var microphone: MicrophoneDevice?
    /// How the recording bubble looks and where it appears.
    public var bubble = BubbleAppearance()
    /// How long the speech model stays in memory without being used.
    public var modelRetention = ModelRetention.always

    public init() {}

    /// Decodes field by field, so a missing or unreadable field (from an older or newer
    /// version) falls back to its default instead of discarding all settings.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DictationSettings()
        isEnabled = container.value(.isEnabled, default: defaults.isEnabled)
        shortcut = container.value(.shortcut, default: defaults.shortcut)
        mode = container.value(.mode, default: defaults.mode)
        language = container.value(.language, default: defaults.language)
        modelID = container.value(.modelID, default: defaults.modelID)
        playsSounds = container.value(.playsSounds, default: defaults.playsSounds)
        startSound = container.value(.startSound, default: defaults.startSound)
        doneSound = container.value(.doneSound, default: defaults.doneSound)
        errorSound = container.value(.errorSound, default: defaults.errorSound)
        ducksAudio = container.value(.ducksAudio, default: defaults.ducksAudio)
        duckingLevel = container.value(.duckingLevel, default: defaults.duckingLevel)
        restoresClipboard = container.value(.restoresClipboard, default: defaults.restoresClipboard)
        learnsFromCorrections = container.value(.learnsFromCorrections, default: defaults.learnsFromCorrections)
        microphone = container.value(.microphone, default: defaults.microphone)
        bubble = container.value(.bubble, default: defaults.bubble)
        modelRetention = container.value(.modelRetention, default: defaults.modelRetention)
    }
}

extension KeyedDecodingContainer {
    /// The decoded value for `key`, or `fallback` when it is missing or unreadable.
    func value<Value: Decodable>(_ key: Key, default fallback: Value) -> Value {
        (try? decodeIfPresent(Value.self, forKey: key)) ?? fallback
    }
}

/// Loads and saves ``DictationSettings`` in user defaults.
@MainActor
public final class DictationSettingsStore {
    public nonisolated static let key = "pavarotti.dictation.settings"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> DictationSettings {
        Self.load(from: defaults)
    }

    public func save(_ settings: DictationSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// The Core Audio UID of the chosen microphone, `nil` for the system default. Meeting
    /// recordings use the same microphone and read it from their audio thread.
    public nonisolated static func chosenMicrophoneUID(defaults: UserDefaults = .standard) -> String? {
        load(from: defaults).microphone?.id
    }

    /// The saved settings, readable off the main actor; defaults when none are saved.
    /// Meeting transcription reads the model and language from here.
    public nonisolated static func load(from defaults: UserDefaults = .standard) -> DictationSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(DictationSettings.self, from: data)
        else {
            return DictationSettings()
        }
        return settings
    }
}
