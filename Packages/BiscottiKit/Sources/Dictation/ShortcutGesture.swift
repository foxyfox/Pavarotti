import Foundation

/// How presses of the dictation shortcut start and stop a dictation.
public enum DictationShortcutMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Listens while the shortcut is held (push to talk).
    case hold
    /// One press starts, the next press stops.
    case toggle
    /// Holding talks like `hold`; a short tap keeps listening until the next press.
    case hybrid

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .hold: String(localized: "Hold to talk")
        case .toggle: String(localized: "Press to start, press again to stop")
        case .hybrid: String(localized: "Hold to talk, or tap to start and stop")
        }
    }
}

/// What the shortcut did, as reported by the shortcut monitor.
public enum ShortcutEvent: Equatable, Sendable {
    case pressed
    case released
    /// Another key was pressed while the shortcut was held, so the press was part of
    /// a key combination such as ⌥E, not a dictation.
    case interrupted
}

/// What the controller should do in response to a shortcut event.
public enum DictationCommand: Equatable, Sendable {
    case start
    case stop
    case cancel
}

/// Turns presses and releases of the shortcut into start, stop and cancel commands.
public struct ShortcutGesture: Sendable {
    public var mode: DictationShortcutMode
    /// In hybrid mode, presses at least this long (seconds) count as holds.
    public let holdThreshold: TimeInterval

    private var isDown = false
    private var isListening = false
    private var pressStartedListening = false
    private var pressedAt: TimeInterval = 0

    public init(mode: DictationShortcutMode, holdThreshold: TimeInterval = 0.35) {
        self.mode = mode
        self.holdThreshold = holdThreshold
    }

    /// Handles one event at `time` (seconds, any monotonic clock).
    public mutating func handle(_ event: ShortcutEvent, at time: TimeInterval) -> DictationCommand? {
        switch event {
        case .pressed: pressed(at: time)
        case .released: released(at: time)
        case .interrupted: interrupted()
        }
    }

    /// Forgets the running dictation, for example after it failed or was stopped from
    /// the menu, so the next press starts a new one.
    public mutating func reset() {
        isListening = false
        pressStartedListening = false
    }

    private mutating func pressed(at time: TimeInterval) -> DictationCommand? {
        // Key repeat sends further presses while the key is held.
        guard !isDown else { return nil }
        isDown = true
        pressedAt = time
        if isListening {
            reset()
            return .stop
        }
        isListening = true
        pressStartedListening = true
        return .start
    }

    private mutating func released(at time: TimeInterval) -> DictationCommand? {
        guard isDown else { return nil }
        isDown = false
        guard isListening, pressStartedListening else { return nil }
        pressStartedListening = false
        switch mode {
        case .toggle:
            return nil
        case .hold:
            reset()
            return .stop
        case .hybrid:
            guard time - pressedAt >= holdThreshold else { return nil }
            reset()
            return .stop
        }
    }

    private mutating func interrupted() -> DictationCommand? {
        guard isDown, isListening, pressStartedListening else { return nil }
        reset()
        return .cancel
    }
}

/// Follows one modifier key through the events of a global key monitor.
public struct ModifierKeyTracker: Sendable {
    public let key: ModifierKey
    private var isDown = false

    public init(key: ModifierKey) {
        self.key = key
    }

    /// Handles a `flagsChanged` event with the event's raw modifier flags.
    public mutating func flagsChanged(rawFlags: UInt) -> ShortcutEvent? {
        let nowDown = rawFlags & key.heldFlag != 0
        guard nowDown != isDown else { return nil }
        isDown = nowDown
        return nowDown ? .pressed : .released
    }

    /// Handles a `keyDown` event of any key.
    public func keyDown() -> ShortcutEvent? {
        isDown ? .interrupted : nil
    }
}
