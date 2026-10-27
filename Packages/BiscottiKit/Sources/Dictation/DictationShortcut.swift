import Foundation

/// A modifier key that starts dictation on its own, such as the Globe key.
public enum ModifierKey: String, Codable, CaseIterable, Sendable, Identifiable {
    case function
    case rightCommand
    case rightOption
    case rightControl
    case rightShift
    case leftCommand
    case leftOption
    case leftControl
    case leftShift

    public var id: String {
        rawValue
    }

    /// The virtual key code macOS reports for this key in `flagsChanged` events.
    public var keyCode: UInt16 {
        switch self {
        case .function: 63
        case .rightCommand: 54
        case .rightOption: 61
        case .rightControl: 62
        case .rightShift: 60
        case .leftCommand: 55
        case .leftOption: 58
        case .leftControl: 59
        case .leftShift: 56
        }
    }

    /// The bit of `NSEvent.modifierFlags.rawValue` that is set while this key is held.
    /// Left and right keys use the device-dependent bits (IOKit's `NX_DEVICE…KEYMASK`),
    /// so holding the left Option key does not hide a press of the right one.
    var heldFlag: UInt {
        switch self {
        case .function: 1 << 23
        case .rightCommand: 1 << 4
        case .rightOption: 1 << 6
        case .rightControl: 1 << 13
        case .rightShift: 1 << 2
        case .leftCommand: 1 << 3
        case .leftOption: 1 << 5
        case .leftControl: 1 << 0
        case .leftShift: 1 << 1
        }
    }

    public var displayName: String {
        switch self {
        case .function: "Fn / Globe"
        case .rightCommand: "Right \u{2318} Command"
        case .rightOption: "Right \u{2325} Option"
        case .rightControl: "Right \u{2303} Control"
        case .rightShift: "Right \u{21E7} Shift"
        case .leftCommand: "Left \u{2318} Command"
        case .leftOption: "Left \u{2325} Option"
        case .leftControl: "Left \u{2303} Control"
        case .leftShift: "Left \u{21E7} Shift"
        }
    }

    /// Whether the key is held according to an event's raw modifier flags.
    public func isHeld(inRawFlags rawFlags: UInt) -> Bool {
        rawFlags & heldFlag != 0
    }

    /// The modifier key with this key code, if any.
    public static func key(forKeyCode keyCode: UInt16) -> ModifierKey? {
        allCases.first { $0.keyCode == keyCode }
    }

    /// Key codes of all modifier keys, including Caps Lock, which cannot be a shortcut.
    static let allModifierKeyCodes: Set<UInt16> = Set(54 ... 63)
}

/// Modifiers held together with the key of a key combination.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)

    /// Reads the device-independent bits of `NSEvent.modifierFlags.rawValue`.
    public init(eventFlags: UInt) {
        var modifiers: KeyModifiers = []
        if eventFlags & 1 << 20 != 0 { modifiers.insert(.command) }
        if eventFlags & 1 << 19 != 0 { modifiers.insert(.option) }
        if eventFlags & 1 << 18 != 0 { modifiers.insert(.control) }
        if eventFlags & 1 << 17 != 0 { modifiers.insert(.shift) }
        self = modifiers
    }

    /// The modifiers as Carbon's `cmdKey | optionKey | …` mask for `RegisterEventHotKey`.
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= 1 << 8 }
        if contains(.shift) { flags |= 1 << 9 }
        if contains(.option) { flags |= 1 << 11 }
        if contains(.control) { flags |= 1 << 12 }
        return flags
    }

    /// Symbols in the order macOS menus show them: ⌃⌥⇧⌘.
    public var symbols: String {
        var text = ""
        if contains(.control) { text += "\u{2303}" }
        if contains(.option) { text += "\u{2325}" }
        if contains(.shift) { text += "\u{21E7}" }
        if contains(.command) { text += "\u{2318}" }
        return text
    }
}

/// The key or key combination that controls dictation.
public enum DictationShortcut: Codable, Hashable, Sendable {
    /// A single modifier key, pressed on its own.
    case modifier(ModifierKey)
    /// A key with modifiers, such as ⌥⌘D. `keyLabel` is what the key showed when it was recorded.
    case combination(keyCode: UInt16, modifiers: KeyModifiers, keyLabel: String)

    /// The default: the Globe key, which is free on most keyboards.
    public static let standard = DictationShortcut.modifier(.function)

    public var displayName: String {
        switch self {
        case let .modifier(key): key.displayName
        case let .combination(_, modifiers, keyLabel): modifiers.symbols + keyLabel
        }
    }
}

/// Readable names for keys, for shortcuts that were not recorded from a live key press.
public enum KeyLabels {
    /// The label for a US-layout key code, or "Key 42" for unknown codes.
    public static func label(for keyCode: UInt16) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }

    /// Function keys F1 to F20, which work as shortcuts without modifiers.
    public static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeyCodes.contains(keyCode)
    }

    private static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90
    ]

    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        64: "F17", 79: "F18", 80: "F19", 90: "F20", 96: "F5", 97: "F6", 98: "F7",
        99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 115: "Home", 116: "Page Up",
        117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down",
        122: "F1", 123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}"
    ]
}
