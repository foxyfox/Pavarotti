import Foundation
import os

public extension TypeWhisperImport {
    /// Whether TypeWhisper is installed or left its preferences behind.
    static var isAvailable: Bool {
        if FileManager.default.fileExists(atPath: appURL.path) {
            return true
        }
        guard let defaults = UserDefaults(suiteName: preferencesDomain) else { return false }
        let keys = SoundSlot.allCases.map(\.preferencesKey) + hotkeySlots.map(\.key) + ["audioDuckingEnabled"]
        return keys.contains { defaults.object(forKey: $0) != nil }
    }

    /// Applies TypeWhisper's settings to `settings`, copying sound files into `library`.
    static func run(
        into settings: DictationSettings,
        library: SoundLibrary,
        defaults: UserDefaults,
        appURL: URL,
        supportDirectory: URL
    ) -> Outcome {
        var outcome = Outcome(settings: settings)
        if let enabled = defaults.object(forKey: "soundFeedbackEnabled") as? Bool {
            outcome.settings.playsSounds = enabled
        }
        let source = SoundSource(library: library, appURL: appURL, supportDirectory: supportDirectory)
        for slot in SoundSlot.allCases {
            let sound = Sound(storedValue: defaults.string(forKey: slot.preferencesKey), defaultBundledName: slot.bundledName)
            do {
                outcome.settings[slot] = try source.choice(for: sound)
                outcome.imported.append(slot.label)
            } catch {
                outcome.skipped.append("\(slot.label) (\(error.localizedDescription))")
            }
        }
        importDucking(into: &outcome, defaults: defaults)
        importShortcut(into: &outcome, defaults: defaults)
        return outcome
    }

    private static func importDucking(into outcome: inout Outcome, defaults: UserDefaults) {
        guard let enabled = defaults.object(forKey: "audioDuckingEnabled") as? Bool else { return }
        outcome.settings.ducksAudio = enabled
        if let level = defaults.object(forKey: "audioDuckingLevel") as? Double {
            outcome.settings.duckingLevel = max(0, min(1, level))
        }
        outcome.imported.append("audio ducking")
    }

    private static func importShortcut(into outcome: inout Outcome, defaults: UserDefaults) {
        for slot in hotkeySlots {
            guard let shortcut = shortcut(fromSlot: slot.key, defaults: defaults) else { continue }
            outcome.settings.shortcut = shortcut
            outcome.settings.mode = slot.mode
            outcome.imported.append("shortcut \(shortcut.displayName)")
            return
        }
        let hasHotkey = hotkeySlots.contains { defaults.object(forKey: $0.key) != nil || defaults.object(forKey: $0.key + "s") != nil }
        if hasHotkey {
            outcome.skipped.append("shortcut (mouse buttons and double taps have no equivalent yet)")
        }
    }
}

/// TypeWhisper's three sound cues and where each one lands in Pavarotti.
enum SoundSlot: CaseIterable {
    case start
    case done
    case error

    var preferencesKey: String {
        switch self {
        case .start: "soundRecordingStarted"
        case .done: "soundTranscriptionSuccess"
        case .error: "soundError"
        }
    }

    var bundledName: String {
        switch self {
        case .start: "recording_start"
        case .done: "transcription_success"
        case .error: "error"
        }
    }

    var label: String {
        switch self {
        case .start: "start sound"
        case .done: "done sound"
        case .error: "error sound"
        }
    }
}

extension DictationSettings {
    subscript(slot: SoundSlot) -> SoundChoice {
        get {
            switch slot {
            case .start: startSound
            case .done: doneSound
            case .error: errorSound
            }
        }
        set {
            switch slot {
            case .start: startSound = newValue
            case .done: doneSound = newValue
            case .error: errorSound = newValue
            }
        }
    }
}

/// Finds the files behind TypeWhisper's sound settings and copies them into the library.
struct SoundSource {
    let library: SoundLibrary
    let appURL: URL
    let supportDirectory: URL

    func choice(for sound: TypeWhisperImport.Sound) throws -> SoundChoice {
        switch sound {
        case .none:
            return .none
        case let .system(name):
            return .system(name)
        case let .bundled(name):
            let resources = appURL.appending(path: "Contents/Resources", directoryHint: .isDirectory)
            let candidates = [
                resources.appending(path: "\(name).wav"),
                resources.appending(path: "Sounds/\(name).wav")
            ]
            let file = try existing(candidates, name: "\(name).wav")
            let imported = try library.importSound(from: file, as: "TypeWhisper \(name).wav")
            return .file(imported)
        case let .custom(fileName):
            let file = try existing([supportDirectory.appending(path: "Sounds/\(fileName)")], name: fileName)
            let imported = try library.importSound(from: file)
            return .file(imported)
        }
    }

    private func existing(_ candidates: [URL], name: String) throws -> URL {
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "\(name) not found"])
        }
        return file
    }
}

// MARK: - Controller

public extension DictationController {
    /// Takes over TypeWhisper's setup the first time Pavarotti finds it, see
    /// ``TypeWhisperImport/LaunchImport``, and logs what it took over.
    func importFromTypeWhisperOnce(defaults: UserDefaults = .standard) {
        let plan = TypeWhisperImport.LaunchImport(
            checkedBefore: defaults.bool(forKey: TypeWhisperImport.checkedKey),
            available: TypeWhisperImport.isAvailable,
            settingsSaved: store.hasSavedSettings
        )
        defaults.set(true, forKey: TypeWhisperImport.checkedKey)
        let summary: String? = switch plan {
        case .nothing: nil
        case .dictionary: importTypeWhisperDictionary()
        case .everything: importFromTypeWhisper()
        }
        if let summary {
            Self.importLogger.info("TypeWhisper: \(summary, privacy: .public)")
        }
    }

    /// Takes over TypeWhisper's sounds, ducking, shortcut and dictionary and returns a summary.
    @discardableResult
    func importFromTypeWhisper() -> String {
        guard let defaults = UserDefaults(suiteName: TypeWhisperImport.preferencesDomain) else {
            return "TypeWhisper's settings could not be read."
        }
        let outcome = TypeWhisperImport.run(
            into: settings,
            library: dependencies.soundLibrary,
            defaults: defaults,
            appURL: TypeWhisperImport.appURL,
            supportDirectory: TypeWhisperImport.supportDirectory
        )
        update { $0 = outcome.settings }
        refreshCustomSounds()
        guard let dictionaryPart = importTypeWhisperDictionary() else { return outcome.summary }
        let nothingElse = outcome.imported.isEmpty && outcome.skipped.isEmpty
        return nothingElse ? dictionaryPart : outcome.summary + " " + dictionaryPart
    }

    /// Adds the corrections from TypeWhisper's dictionary that Pavarotti's lacks; `nil`
    /// when TypeWhisper has no dictionary.
    private func importTypeWhisperDictionary() -> String? {
        TypeWhisperImport.importDictionary(
            into: dependencies.dictionary,
            supportDirectory: TypeWhisperImport.supportDirectory
        )
    }

    private static let importLogger = Logger(subsystem: "de.foxagon.pavarotti", category: "TypeWhisperImport")
}

public extension TypeWhisperImport {
    static let checkedKey = "pavarotti.dictation.checkedTypeWhisper"

    /// What to take over from TypeWhisper at launch. On a fresh install everything; on an
    /// install whose settings were already saved only the dictionary, which adds just the
    /// corrections Pavarotti lacks, so sounds, ducking and shortcut set in Pavarotti stay.
    /// Runs once; after that only Pavarotti's own settings count.
    enum LaunchImport: Equatable {
        case nothing
        case dictionary
        case everything

        init(checkedBefore: Bool, available: Bool, settingsSaved: Bool) {
            if checkedBefore || !available {
                self = .nothing
            } else {
                self = settingsSaved ? .dictionary : .everything
            }
        }
    }
}

public extension TypeWhisperImport {
    /// Takes over the corrections from TypeWhisper's dictionary and describes the result,
    /// or returns `nil` when TypeWhisper has no dictionary.
    @MainActor
    static func importDictionary(into dictionary: PersonalDictionary, supportDirectory: URL) -> String? {
        let store = TypeWhisperDictionaryReader.storeURL(in: supportDirectory)
        guard FileManager.default.fileExists(atPath: store.path) else { return nil }
        do {
            let contents = try TypeWhisperDictionaryReader.read(storeAt: store)
            let added = dictionary.merge(contents.corrections)
            var text = "Dictionary: \(added) of \(contents.corrections.count) corrections added."
            switch contents.termCount {
            case 0: break
            case 1: text += " 1 term left out, Cohere cannot use it."
            default: text += " \(contents.termCount) terms left out, Cohere cannot use them."
            }
            if !contents.leftOutLearned.isEmpty {
                text += " Learned rewrites left out: \(contents.leftOutLearned.joined(separator: ", "))."
            }
            return text
        } catch {
            return "Dictionary skipped: \(error.localizedDescription)"
        }
    }
}
