import Foundation

/// Takes over dictation settings from an installed TypeWhisper: the start, done and
/// error sounds, audio ducking and the push-to-talk shortcut.
///
/// Reads TypeWhisper's preferences (`com.typewhisper.mac`) and copies the sound files
/// it uses into Pavarotti's sound library. Nothing is written back to TypeWhisper.
public enum TypeWhisperImport {
    public static let preferencesDomain = "com.typewhisper.mac"
    public static let appURL = URL(fileURLWithPath: "/Applications/TypeWhisper.app", isDirectory: true)
    public static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "TypeWhisper", directoryHint: .isDirectory)
    }

    /// What one import changed and what it had to leave out.
    public struct Outcome: Equatable, Sendable {
        public var settings: DictationSettings
        public var imported: [String] = []
        public var skipped: [String] = []

        public var summary: String {
            var parts: [String] = []
            if !imported.isEmpty {
                parts.append("Imported: \(imported.joined(separator: ", ")).")
            }
            if !skipped.isEmpty {
                parts.append("Skipped: \(skipped.joined(separator: "; ")).")
            }
            return parts.isEmpty ? "Nothing to import from TypeWhisper." : parts.joined(separator: " ")
        }
    }

    /// A sound setting as TypeWhisper stores it (`bundled:recording_start`, `system:Tink`, …).
    enum Sound: Equatable {
        case none
        case system(String)
        case bundled(String)
        case custom(String)

        init(storedValue: String?, defaultBundledName: String) {
            guard let value = storedValue else {
                self = .bundled(defaultBundledName)
                return
            }
            if value == "none" {
                self = .none
            } else if let name = Self.value(of: value, prefix: "bundled:") {
                self = .bundled(name)
            } else if let name = Self.value(of: value, prefix: "system:") {
                self = .system(name)
            } else if let name = Self.value(of: value, prefix: "custom:") {
                self = .custom(name)
            } else {
                self = .none
            }
        }

        private static func value(of stored: String, prefix: String) -> String? {
            guard stored.hasPrefix(prefix) else { return nil }
            let name = String(stored.dropFirst(prefix.count))
            return name.isEmpty ? nil : name
        }
    }

    /// A TypeWhisper hot key as stored in its preferences (JSON).
    struct Hotkey: Decodable, Equatable {
        let keyCode: UInt16
        let modifierFlags: UInt
        let isFn: Bool
        let isDoubleTap: Bool?
        let mouseButton: UInt16?
    }

    /// One of TypeWhisper's shortcut slots and the mode it stands for.
    struct HotkeySlot {
        let key: String
        let mode: DictationShortcutMode
    }

    /// TypeWhisper's shortcut slots, most fitting first.
    static let hotkeySlots = [
        HotkeySlot(key: "pttHotkey", mode: .hold),
        HotkeySlot(key: "hybridHotkey", mode: .hybrid),
        HotkeySlot(key: "toggleHotkey", mode: .toggle)
    ]

    /// The Pavarotti shortcut for a TypeWhisper hot key, or `nil` when it has no
    /// equivalent (mouse buttons, double taps, modifier-only combinations).
    static func shortcut(for hotkey: Hotkey) -> DictationShortcut? {
        guard hotkey.mouseButton == nil, hotkey.isDoubleTap != true else { return nil }
        if hotkey.isFn {
            return .modifier(.function)
        }
        if ModifierKey.allModifierKeyCodes.contains(hotkey.keyCode) {
            guard hotkey.modifierFlags & deviceIndependentModifierMask == 0 else { return nil }
            return ModifierKey.key(forKeyCode: hotkey.keyCode).map(DictationShortcut.modifier)
        }
        // TypeWhisper's marker for a combination of modifiers only.
        guard hotkey.keyCode != 0xFFFF else { return nil }
        let modifiers = KeyModifiers(eventFlags: hotkey.modifierFlags)
        guard !modifiers.isEmpty || KeyLabels.isFunctionKey(hotkey.keyCode) else { return nil }
        return .combination(keyCode: hotkey.keyCode, modifiers: modifiers, keyLabel: KeyLabels.label(for: hotkey.keyCode))
    }

    /// Reads the first usable hot key from TypeWhisper's slots. The newer keys hold a
    /// JSON array, the older ones a single hot key.
    static func shortcut(fromSlot slot: String, defaults: UserDefaults) -> DictationShortcut? {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: slot + "s"),
           let hotkeys = try? decoder.decode([Hotkey].self, from: data)
        {
            return hotkeys.lazy.compactMap(shortcut(for:)).first
        }
        if let data = defaults.data(forKey: slot), let hotkey = try? decoder.decode(Hotkey.self, from: data) {
            return shortcut(for: hotkey)
        }
        return nil
    }

    /// Command, Option, Control and Shift in `NSEvent.modifierFlags.rawValue`.
    private static let deviceIndependentModifierMask: UInt = 0b1111 << 17
}
