import CohereTranscribe
import Foundation
import Testing
@testable import Dictation

@Suite("DictationSettings")
struct DictationSettingsTests {
    @Test("defaults")
    func defaults() {
        let settings = DictationSettings()
        #expect(settings.isEnabled)
        #expect(settings.shortcut == .modifier(.function))
        #expect(settings.mode == .hybrid)
        #expect(settings.language == .automatic)
        #expect(settings.modelID == CohereModel.recommended.id)
        #expect(settings.startSound == .system("Tink"))
        #expect(!settings.ducksAudio)
        #expect(settings.restoresClipboard)
        #expect(settings.bubble == BubbleAppearance(size: .compact, style: .glass, position: .bottom))
        #expect(settings.modelRetention == .always)
    }

    @Test("round trip through JSON")
    func roundTrip() throws {
        var settings = DictationSettings()
        settings.shortcut = .combination(keyCode: 2, modifiers: [.command, .shift], keyLabel: "D")
        settings.mode = .toggle
        settings.language = try #require(TranscriptionLanguage(rawValue: "fr"))
        settings.startSound = .file("TypeWhisper recording_start.wav")
        settings.doneSound = .none
        settings.ducksAudio = true
        settings.duckingLevel = 0.35
        settings.learnsFromCorrections = false
        settings.microphone = MicrophoneDevice(id: "AppleUSBAudioEngine:Apple Inc.:Studio Display", name: "Studio Display Microphone")
        settings.bubble = BubbleAppearance(size: .minimal, style: .frosted, position: .top)
        settings.modelRetention = .fifteenMinutes
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DictationSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test("missing and unreadable fields fall back to their defaults")
    func tolerantDecoding() throws {
        let json = Data(#"{"mode": "toggle", "language": "klingon", "ducksAudio": "yes", "duckingLevel": 0.5}"#.utf8)
        let decoded = try JSONDecoder().decode(DictationSettings.self, from: json)
        var expected = DictationSettings()
        expected.mode = .toggle
        expected.duckingLevel = 0.5
        #expect(decoded == expected)
        #expect(decoded.microphone == nil)
    }

    @Test("a language the new model does not know falls back to automatic")
    func modelChangeKeepsKnownLanguages() throws {
        var settings = DictationSettings()
        settings.modelID = CohereModel.small.id
        settings.language = try #require(TranscriptionLanguage(rawValue: "sv"))
        settings.modelID = CohereModel.small.id
        #expect(settings.language.rawValue == "sv")
        settings.modelID = CohereModel.fast.id
        #expect(settings.language == .automatic)

        settings.language = .german
        settings.modelID = CohereModel.small.id
        #expect(settings.language == .german)
    }

    @Test("the model stays loaded unless an idle limit is chosen")
    func modelRetention() throws {
        #expect(ModelRetention.always.idleLimit == nil)
        #expect(ModelRetention.fiveMinutes.idleLimit == .seconds(300))
        #expect(ModelRetention.fifteenMinutes.idleLimit == .seconds(900))
        #expect(ModelRetention.oneHour.idleLimit == .seconds(3600))
        let json = Data(#"{"modelRetention": "forever"}"#.utf8)
        #expect(try JSONDecoder().decode(DictationSettings.self, from: json).modelRetention == .always)
    }

    @Test("settings saved before the bubble choices get the small glass bubble")
    func bubbleDefaultsForOlderSettings() throws {
        let json = Data(#"{"isEnabled": true, "mode": "hybrid"}"#.utf8)
        let decoded = try JSONDecoder().decode(DictationSettings.self, from: json)
        #expect(decoded.bubble == BubbleAppearance())
    }

    @Test("an unknown bubble choice keeps the other two")
    func tolerantBubbleDecoding() throws {
        let json = Data(#"{"bubble": {"size": "minimal", "style": "chrome", "position": "top"}}"#.utf8)
        let decoded = try JSONDecoder().decode(DictationSettings.self, from: json)
        #expect(decoded.bubble == BubbleAppearance(size: .minimal, style: .glass, position: .top))
    }

    @Test("the store saves and loads, and falls back to defaults")
    @MainActor
    func store() throws {
        let suite = "pavarotti.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DictationSettingsStore(defaults: defaults)
        #expect(store.load() == DictationSettings())

        var settings = DictationSettings()
        settings.isEnabled = false
        settings.errorSound = .system("Funk")
        store.save(settings)
        #expect(DictationSettingsStore(defaults: defaults).load() == settings)

        defaults.set(Data("not json".utf8), forKey: DictationSettingsStore.key)
        #expect(store.load() == DictationSettings())
    }

    @Test("meeting recordings read the chosen microphone")
    @MainActor
    func chosenMicrophoneUID() throws {
        let suite = "pavarotti.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DictationSettingsStore.chosenMicrophoneUID(defaults: defaults) == nil)

        var settings = DictationSettings()
        settings.microphone = MicrophoneDevice(id: "AppleUSBAudioEngine:Apple Inc.:Studio Display", name: "Studio Display Microphone")
        DictationSettingsStore(defaults: defaults).save(settings)
        #expect(DictationSettingsStore.chosenMicrophoneUID(defaults: defaults) == "AppleUSBAudioEngine:Apple Inc.:Studio Display")
    }

    @Test("sound choice names")
    func soundChoiceNames() {
        #expect(SoundChoice.none.displayName == "None")
        #expect(SoundChoice.system("Pop").displayName == "Pop")
        #expect(SoundChoice.file("TypeWhisper error.wav").displayName == "TypeWhisper error")
    }
}

@Suite("SoundLibrary")
struct SoundLibraryTests {
    @Test("imports, lists and finds sound files")
    func importAndList() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pavarotti-sounds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let wav = source.appending(path: "ding.wav")
        try Data("RIFF".utf8).write(to: wav)
        let text = source.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)

        let library = SoundLibrary(directory: root.appending(path: "library"))
        #expect(library.customSoundNames().isEmpty)
        #expect(try library.importSound(from: wav) == "ding.wav")
        #expect(try library.importSound(from: wav, as: "Beta.wav") == "Beta.wav")
        // Importing again replaces the file instead of failing.
        #expect(try library.importSound(from: wav) == "ding.wav")
        #expect(library.customSoundNames() == ["Beta.wav", "ding.wav"])
        #expect(library.url(for: .file("ding.wav")) != nil)
        #expect(library.url(for: .file("missing.wav")) == nil)
        #expect(library.url(for: .none) == nil)

        #expect(throws: DictationError.unsupportedSoundFile("notes.txt")) {
            try library.importSound(from: text)
        }
    }
}
