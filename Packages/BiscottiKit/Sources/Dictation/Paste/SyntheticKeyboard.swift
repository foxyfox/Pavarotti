import CoreGraphics
import Foundation
import os

// Pavarotti: the paste shortcut as a real key chord, ported from Andreas's TypeWhisper fork
// (f86f5e9, "Send paste and copy as real modifier key chords").
//
// Remote desktop clients (Screen Sharing, Windows App) track modifiers from their own
// flagsChanged events and only see the device-dependent bit of the physical key. A ⌘V whose
// key events merely carry `.maskCommand` therefore arrives there as a bare "v". The paste is
// posted as a chord instead: Command down, V down, V up, Command up.

/// Marks the key events Pavarotti posts itself, so its own shortcut monitor lets them pass.
public enum SyntheticKeyboardMarker {
    /// "PAVPASTE".
    public static let pasteShortcut: Int64 = 0x5041_5650_4153_5445

    public static func isPasteShortcut(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == pasteShortcut
    }
}

/// Left Command, the modifier the paste chord holds down.
enum ChordModifier {
    static let keyCode: CGKeyCode = 0x37
    /// Device-dependent bit of the left Command key (NX_DEVICELCMDKEYMASK). Remote clients
    /// derive the physical key, and with it the forwarded scancode, from this bit.
    static let deviceFlagBit: UInt64 = 0x08

    /// Flags of every event while Command is held.
    static var heldFlagsRaw: UInt64 {
        CGEventFlags.maskCommand.rawValue | deviceFlagBit | CGEventFlags.maskNonCoalesced.rawValue
    }
}

/// Pauses of a chord, in microseconds.
struct SyntheticChordTiming: Equatable {
    /// Pause after each event.
    let eventGap: UInt32
    /// How long Command stays down after the key-up.
    let modifierHoldAfterKeyUp: UInt32

    /// Local apps read the explicit flags of the key events, so short pauses suffice.
    static let local = SyntheticChordTiming(eventGap: 8000, modifierHoldAfterKeyUp: 10000)
    /// Screen Sharing delays flag changes, and clients that poll the modifier state need
    /// Command still down after the key.
    static let remote = SyntheticChordTiming(eventGap: 20000, modifierHoldAfterKeyUp: 100_000)
}

/// One planned key event. Planning is pure, so tests check sequences without posting.
struct SyntheticKeyEvent: Equatable {
    let keyCode: CGKeyCode
    let isDown: Bool
    /// The event's complete flags, see `SyntheticKeyEventPostingOptions.additionalFlagsRaw`.
    let flagsRaw: UInt64
    /// Pause after posting this event, in microseconds.
    let delayAfter: UInt32

    /// Command down, key down, key up, Command up. The held flags carry the device bit of
    /// the left key; the Command-up event only keeps `maskNonCoalesced`.
    static func commandChord(keyCode: CGKeyCode, timing: SyntheticChordTiming) -> [SyntheticKeyEvent] {
        let held = ChordModifier.heldFlagsRaw
        let released = CGEventFlags.maskNonCoalesced.rawValue
        return [
            SyntheticKeyEvent(keyCode: ChordModifier.keyCode, isDown: true, flagsRaw: held, delayAfter: timing.eventGap),
            SyntheticKeyEvent(keyCode: keyCode, isDown: true, flagsRaw: held, delayAfter: timing.eventGap),
            SyntheticKeyEvent(keyCode: keyCode, isDown: false, flagsRaw: held, delayAfter: timing.modifierHoldAfterKeyUp),
            SyntheticKeyEvent(keyCode: ChordModifier.keyCode, isDown: false, flagsRaw: released, delayAfter: timing.eventGap)
        ]
    }

    /// The earlier ⌘V: key down and up that only carry `.maskCommand`.
    static func flagsOnly(keyCode: CGKeyCode) -> [SyntheticKeyEvent] {
        let flags = CGEventFlags.maskCommand.rawValue
        return [
            SyntheticKeyEvent(keyCode: keyCode, isDown: true, flagsRaw: flags, delayAfter: 0),
            SyntheticKeyEvent(keyCode: keyCode, isDown: false, flagsRaw: flags, delayAfter: 0)
        ]
    }
}

/// Where synthetic key events enter the event stream.
enum SyntheticKeyEventTap: String {
    case hid
    case session

    var location: CGEventTapLocation {
        switch self {
        case .hid: .cghidEventTap
        case .session: .cgSessionEventTap
        }
    }
}

/// The state table of the event source a sequence is created with.
enum SyntheticKeyEventSourceState: String {
    /// Own state per sequence, meant for remote control programs: physically held
    /// modifiers (such as the dictation key) do not leak into the events.
    case privateState = "private"
    case combinedSessionState = "combined"
    case hidSystemState = "hid"

    var stateID: CGEventSourceStateID {
        switch self {
        case .privateState: .privateState
        case .combinedSessionState: .combinedSessionState
        case .hidSystemState: .hidSystemState
        }
    }
}

/// How a sequence of key events is created and posted.
struct SyntheticKeyEventPostingOptions: Equatable {
    /// Undocumented bit Core Graphics sets on the events it creates. The chord keeps it next
    /// to its explicit flags.
    static let generatedEventFlagBit: UInt64 = 0x2000_0000

    var tap: SyntheticKeyEventTap
    /// `nil` creates the events without a source.
    var sourceState: SyntheticKeyEventSourceState?
    var marker: Int64?
    var keyboardType: Int64?
    /// Raw flag bits added to the planned flags of every event.
    var additionalFlagsRaw: UInt64 = 0

    static func pasteChord(settings: SyntheticKeyboardSettings, keyboardType: Int64?) -> SyntheticKeyEventPostingOptions {
        SyntheticKeyEventPostingOptions(
            tap: settings.eventTap,
            sourceState: settings.sourceState,
            marker: SyntheticKeyboardMarker.pasteShortcut,
            keyboardType: keyboardType,
            additionalFlagsRaw: generatedEventFlagBit
        )
    }

    /// The earlier flags-only paste: no source, session tap, but still marked.
    static let flagsOnlyPaste = SyntheticKeyEventPostingOptions(
        tap: .session,
        sourceState: nil,
        marker: SyntheticKeyboardMarker.pasteShortcut,
        keyboardType: nil
    )
}

/// Hidden settings for the paste shortcut, without UI. For example
/// `defaults write de.foxagon.pavarotti syntheticPasteChordEnabled -bool NO` goes back to
/// the flags-only key events; `syntheticKeyEventTap` (`hid`, `session`) and
/// `syntheticKeyEventSourceState` (`private`, `combined`, `hid`) isolate a variant at fault.
struct SyntheticKeyboardSettings: Equatable {
    var chordEnabled = true
    var eventTap = SyntheticKeyEventTap.hid
    var sourceState = SyntheticKeyEventSourceState.privateState

    static func load(from defaults: UserDefaults) -> SyntheticKeyboardSettings {
        var settings = SyntheticKeyboardSettings()
        if let enabled = defaults.object(forKey: "syntheticPasteChordEnabled") as? Bool {
            settings.chordEnabled = enabled
        }
        if let tap = defaults.string(forKey: "syntheticKeyEventTap").flatMap(SyntheticKeyEventTap.init(rawValue:)) {
            settings.eventTap = tap
        }
        if let state = defaults.string(forKey: "syntheticKeyEventSourceState")
            .flatMap(SyntheticKeyEventSourceState.init(rawValue:))
        {
            settings.sourceState = state
        }
        return settings
    }
}

/// Posts planned key events.
protocol SyntheticKeyEventPosting: Sendable {
    /// Queues the events behind earlier sequences and returns at once. `completion` runs once
    /// the last pause has passed, with `false` when nothing was posted.
    func enqueue(
        _ events: [SyntheticKeyEvent],
        options: SyntheticKeyEventPostingOptions,
        completion: @escaping @Sendable (Bool) -> Void
    )
}

extension SyntheticKeyEventPosting {
    /// Queues the events and waits until the last pause has passed. Returns `false` when
    /// nothing was posted.
    func post(_ events: [SyntheticKeyEvent], options: SyntheticKeyEventPostingOptions) async -> Bool {
        await withCheckedContinuation { continuation in
            enqueue(events, options: options) { posted in
                continuation.resume(returning: posted)
            }
        }
    }
}

/// Posts key events on one serial queue. A sequence runs as one block, so nothing lands
/// between Command down and up, and the pauses never block the main thread.
final class CGEventKeyPoster: SyntheticKeyEventPosting {
    /// Posts one event at a tap location.
    typealias EventSink = @Sendable (CGEvent, CGEventTapLocation) -> Void
    /// Pauses the posting queue, in microseconds.
    typealias Sleep = @Sendable (UInt32) -> Void
    /// Creates one key event: source, virtual key, key down.
    typealias EventFactory = @Sendable (CGEventSource?, CGKeyCode, Bool) -> CGEvent?

    static let systemEventSink: EventSink = { event, tap in event.post(tap: tap) }
    static let systemSleep: Sleep = { microseconds in _ = usleep(microseconds) }
    static let systemEventFactory: EventFactory = { source, keyCode, keyDown in
        // A modifier key code becomes a flagsChanged event on its own.
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
    }

    private static let logger = Logger(subsystem: "de.foxagon.pavarotti", category: "SyntheticKeyboard")

    private let queue = DispatchQueue(label: "de.foxagon.pavarotti.synthetic-keyboard", qos: .userInteractive)
    private let postEvent: EventSink
    private let sleep: Sleep
    private let eventFactory: EventFactory

    init(
        postEvent: @escaping EventSink = CGEventKeyPoster.systemEventSink,
        sleep: @escaping Sleep = CGEventKeyPoster.systemSleep,
        eventFactory: @escaping EventFactory = CGEventKeyPoster.systemEventFactory
    ) {
        self.postEvent = postEvent
        self.sleep = sleep
        self.eventFactory = eventFactory
    }

    func enqueue(
        _ events: [SyntheticKeyEvent],
        options: SyntheticKeyEventPostingOptions,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async {
            completion(self.postSequence(events, options: options))
        }
    }

    /// Creates the events without posting them. Returns `nil` when any event cannot be
    /// created, so a Command-down is never posted without its Command-up.
    static func makeEvents(
        for events: [SyntheticKeyEvent],
        options: SyntheticKeyEventPostingOptions,
        eventFactory: EventFactory = CGEventKeyPoster.systemEventFactory
    ) -> [CGEvent]? {
        // One source per sequence. Without one, Core Graphics creates the events anyway.
        let source = options.sourceState.flatMap { CGEventSource(stateID: $0.stateID) }
        var created: [CGEvent] = []
        for planned in events {
            guard let event = eventFactory(source, planned.keyCode, planned.isDown) else { return nil }
            event.flags = CGEventFlags(rawValue: planned.flagsRaw | options.additionalFlagsRaw)
            if let marker = options.marker {
                event.setIntegerValueField(.eventSourceUserData, value: marker)
            }
            if let keyboardType = options.keyboardType {
                event.setIntegerValueField(.keyboardEventKeyboardType, value: keyboardType)
            }
            created.append(event)
        }
        return created
    }

    /// Runs on `queue` only.
    private func postSequence(_ events: [SyntheticKeyEvent], options: SyntheticKeyEventPostingOptions) -> Bool {
        guard let created = Self.makeEvents(for: events, options: options, eventFactory: eventFactory) else {
            Self.logger.error("Could not create all \(events.count, privacy: .public) key events; posted none")
            return false
        }
        for (event, planned) in zip(created, events) {
            postEvent(event, options.tap.location)
            if planned.delayAfter > 0 {
                sleep(planned.delayAfter)
            }
        }
        return true
    }
}
