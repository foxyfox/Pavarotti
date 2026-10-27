import Foundation
import Testing
@testable import Dictation

@Suite("TypeWhisperImport")
struct TypeWhisperImportTests {
    // MARK: - Parsing

    @Test("sound settings as TypeWhisper stores them")
    func soundParsing() {
        typealias Sound = TypeWhisperImport.Sound
        #expect(Sound(storedValue: nil, defaultBundledName: "error") == .bundled("error"))
        #expect(Sound(storedValue: "none", defaultBundledName: "error") == Sound.none)
        #expect(Sound(storedValue: "bundled:recording_start", defaultBundledName: "error") == .bundled("recording_start"))
        #expect(Sound(storedValue: "system:Tink", defaultBundledName: "error") == .system("Tink"))
        #expect(Sound(storedValue: "custom:Beep.wav", defaultBundledName: "error") == .custom("Beep.wav"))
        #expect(Sound(storedValue: "system:", defaultBundledName: "error") == Sound.none)
        #expect(Sound(storedValue: "something else", defaultBundledName: "error") == Sound.none)
    }

    @Test("hot keys that have a Pavarotti equivalent")
    func supportedHotkeys() {
        #expect(shortcut(keyCode: 63, flags: 0, isFn: true) == .modifier(.function))
        #expect(shortcut(keyCode: 61, flags: 0) == .modifier(.rightOption))
        let commandShiftD = shortcut(keyCode: 2, flags: 1 << 20 | 1 << 17)
        #expect(commandShiftD == .combination(keyCode: 2, modifiers: [.command, .shift], keyLabel: "D"))
        #expect(shortcut(keyCode: 96, flags: 0) == .combination(keyCode: 96, modifiers: [], keyLabel: "F5"))
    }

    @Test("hot keys without an equivalent are left out")
    func unsupportedHotkeys() {
        #expect(shortcut(keyCode: 0, flags: 0, mouseButton: 3) == nil)
        #expect(shortcut(keyCode: 61, flags: 0, isDoubleTap: true) == nil)
        #expect(shortcut(keyCode: 0xFFFF, flags: 1 << 20 | 1 << 19) == nil)
        // A modifier key held together with other modifiers.
        #expect(shortcut(keyCode: 61, flags: 1 << 20) == nil)
        // A plain letter would type into every app.
        #expect(shortcut(keyCode: 2, flags: 0) == nil)
    }

    @Test("the array slot wins over the single slot and skips unusable hot keys")
    func slotReading() throws {
        try withDefaults { defaults in
            let single = try hotkeyJSON(keyCode: 61, flags: 0)
            defaults.set(single, forKey: "pttHotkey")
            #expect(TypeWhisperImport.shortcut(fromSlot: "pttHotkey", defaults: defaults) == .modifier(.rightOption))

            let mouse = Hotkey(keyCode: 0, modifierFlags: 0, isFn: false, isDoubleTap: nil, mouseButton: 4)
            let globe = Hotkey(keyCode: 63, modifierFlags: 0, isFn: true, isDoubleTap: nil, mouseButton: nil)
            try defaults.set(JSONEncoder().encode([mouse, globe]), forKey: "pttHotkeys")
            #expect(TypeWhisperImport.shortcut(fromSlot: "pttHotkey", defaults: defaults) == .modifier(.function))
            #expect(TypeWhisperImport.shortcut(fromSlot: "toggleHotkey", defaults: defaults) == nil)
        }
    }

    // MARK: - Running the import

    @Test("imports bundled and custom sounds, ducking and the shortcut")
    func fullImport() throws {
        try withFixture { fixture in
            fixture.defaults.set("custom:Chime.wav", forKey: "soundRecordingStarted")
            fixture.defaults.set("system:Glass", forKey: "soundTranscriptionSuccess")
            // soundError stays unset, which means TypeWhisper's bundled error sound.
            fixture.defaults.set(true, forKey: "audioDuckingEnabled")
            fixture.defaults.set(0.3, forKey: "audioDuckingLevel")
            try fixture.defaults.set(hotkeyJSON(keyCode: 2, flags: 1 << 20 | 1 << 17), forKey: "toggleHotkey")
            try fixture.addCustomSound("Chime.wav")
            try fixture.addBundledSound("error", inSoundsFolder: true)

            let outcome = fixture.run()

            #expect(outcome.settings.startSound == .file("Chime.wav"))
            #expect(outcome.settings.doneSound == .system("Glass"))
            #expect(outcome.settings.errorSound == .file("TypeWhisper error.wav"))
            #expect(outcome.settings.ducksAudio)
            #expect(outcome.settings.duckingLevel == 0.3)
            #expect(outcome.settings.shortcut == .combination(keyCode: 2, modifiers: [.command, .shift], keyLabel: "D"))
            #expect(outcome.settings.mode == .toggle)
            #expect(outcome.skipped.isEmpty)
            #expect(fixture.library.customSoundNames() == ["Chime.wav", "TypeWhisper error.wav"])
        }
    }

    @Test("missing files and mouse buttons are reported, the rest stays")
    func partialImport() throws {
        try withFixture { fixture in
            fixture.defaults.set(false, forKey: "soundFeedbackEnabled")
            fixture.defaults.set("none", forKey: "soundTranscriptionSuccess")
            let mouse = Hotkey(keyCode: 0, modifierFlags: 0, isFn: false, isDoubleTap: nil, mouseButton: 3)
            try fixture.defaults.set(JSONEncoder().encode(mouse), forKey: "pttHotkey")
            // Older TypeWhisper builds keep the sounds right in Resources.
            try fixture.addBundledSound("error", inSoundsFolder: false)

            var before = DictationSettings()
            before.shortcut = .modifier(.rightCommand)
            let outcome = fixture.run(into: before)

            #expect(!outcome.settings.playsSounds)
            #expect(outcome.settings.startSound == before.startSound)
            #expect(outcome.settings.doneSound == SoundChoice.none)
            #expect(outcome.settings.errorSound == .file("TypeWhisper error.wav"))
            #expect(outcome.settings.shortcut == .modifier(.rightCommand))
            #expect(!outcome.settings.ducksAudio)
            #expect(outcome.imported == ["done sound", "error sound"])
            #expect(outcome.skipped.count == 2)
            #expect(outcome.summary.hasPrefix("Imported: done sound, error sound. Skipped: start sound"))
        }
    }

    @Test("an empty TypeWhisper says so")
    func emptySummary() {
        let outcome = TypeWhisperImport.Outcome(settings: DictationSettings())
        #expect(outcome.summary == "Nothing to import from TypeWhisper.")
    }
}

// MARK: - Helpers

/// Mirrors TypeWhisper's stored hot key, for writing test preferences.
private struct Hotkey: Encodable {
    let keyCode: UInt16
    let modifierFlags: UInt
    let isFn: Bool
    let isDoubleTap: Bool?
    let mouseButton: UInt16?
}

private func hotkeyJSON(keyCode: UInt16, flags: UInt) throws -> Data {
    try JSONEncoder().encode(Hotkey(keyCode: keyCode, modifierFlags: flags, isFn: false, isDoubleTap: nil, mouseButton: nil))
}

private func shortcut(
    keyCode: UInt16,
    flags: UInt,
    isFn: Bool = false,
    isDoubleTap: Bool? = nil,
    mouseButton: UInt16? = nil
) -> DictationShortcut? {
    let hotkey = TypeWhisperImport.Hotkey(
        keyCode: keyCode,
        modifierFlags: flags,
        isFn: isFn,
        isDoubleTap: isDoubleTap,
        mouseButton: mouseButton
    )
    return TypeWhisperImport.shortcut(for: hotkey)
}

private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "pavarotti.tests.typewhisper.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

/// A fake TypeWhisper install: preferences, an app bundle and a support folder.
private struct ImportFixture {
    let defaults: UserDefaults
    let root: URL
    let library: SoundLibrary

    var appURL: URL {
        root.appending(path: "TypeWhisper.app", directoryHint: .isDirectory)
    }

    var supportDirectory: URL {
        root.appending(path: "Support", directoryHint: .isDirectory)
    }

    func addCustomSound(_ name: String) throws {
        let folder = supportDirectory.appending(path: "Sounds", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("RIFF".utf8).write(to: folder.appending(path: name))
    }

    func addBundledSound(_ name: String, inSoundsFolder: Bool) throws {
        var folder = appURL.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        if inSoundsFolder {
            folder = folder.appending(path: "Sounds", directoryHint: .isDirectory)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("RIFF".utf8).write(to: folder.appending(path: "\(name).wav"))
    }

    func run(into settings: DictationSettings = DictationSettings()) -> TypeWhisperImport.Outcome {
        TypeWhisperImport.run(
            into: settings,
            library: library,
            defaults: defaults,
            appURL: appURL,
            supportDirectory: supportDirectory
        )
    }
}

private func withFixture(_ body: (ImportFixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pavarotti-typewhisper-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try withDefaults { defaults in
        let library = SoundLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
        try body(ImportFixture(defaults: defaults, root: root, library: library))
    }
}
