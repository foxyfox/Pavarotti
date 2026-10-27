import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import Dictation

@Suite("Synthetic keyboard")
struct SyntheticKeyboardTests {
    private static let held = CGEventFlags.maskCommand.rawValue | 0x08 | CGEventFlags.maskNonCoalesced.rawValue
    private static var markedChord: SyntheticKeyEventPostingOptions {
        SyntheticKeyEventPostingOptions(
            tap: .hid,
            sourceState: nil,
            marker: SyntheticKeyboardMarker.pasteShortcut,
            keyboardType: 40,
            additionalFlagsRaw: SyntheticKeyEventPostingOptions.generatedEventFlagBit
        )
    }

    @Test("the paste chord holds left Command around the key")
    func commandChord() {
        #expect(SyntheticKeyEvent.commandChord(keyCode: 9, timing: .remote) == [
            SyntheticKeyEvent(keyCode: 0x37, isDown: true, flagsRaw: Self.held, delayAfter: 20000),
            SyntheticKeyEvent(keyCode: 9, isDown: true, flagsRaw: Self.held, delayAfter: 20000),
            SyntheticKeyEvent(keyCode: 9, isDown: false, flagsRaw: Self.held, delayAfter: 100_000),
            SyntheticKeyEvent(keyCode: 0x37, isDown: false, flagsRaw: CGEventFlags.maskNonCoalesced.rawValue, delayAfter: 20000)
        ])
        #expect(SyntheticKeyEvent.commandChord(keyCode: 9, timing: .local).map(\.delayAfter) == [8000, 8000, 10000, 8000])
    }

    @Test("the flags-only paste is a key down and up with Command")
    func flagsOnly() {
        let flags = CGEventFlags.maskCommand.rawValue
        #expect(SyntheticKeyEvent.flagsOnly(keyCode: 9) == [
            SyntheticKeyEvent(keyCode: 9, isDown: true, flagsRaw: flags, delayAfter: 0),
            SyntheticKeyEvent(keyCode: 9, isDown: false, flagsRaw: flags, delayAfter: 0)
        ])
    }

    @Test("created events carry the flags, the marker and the keyboard type")
    func createdEvents() throws {
        let planned = SyntheticKeyEvent.commandChord(keyCode: 9, timing: .local)
        let events = try #require(CGEventKeyPoster.makeEvents(for: planned, options: Self.markedChord))

        #expect(events.count == planned.count)
        for (event, plan) in zip(events, planned) {
            #expect(event.flags.rawValue == plan.flagsRaw | SyntheticKeyEventPostingOptions.generatedEventFlagBit)
            #expect(event.getIntegerValueField(.keyboardEventKeycode) == Int64(plan.keyCode))
            #expect(event.getIntegerValueField(.keyboardEventKeyboardType) == 40)
            #expect(SyntheticKeyboardMarker.isPasteShortcut(event))
        }
        let unmarked = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        #expect(!SyntheticKeyboardMarker.isPasteShortcut(unmarked))
    }

    @Test("the poster posts the whole sequence with its pauses")
    func posterOrder() async {
        let log = EventLog()
        let poster = CGEventKeyPoster(
            postEvent: { event, tap in
                log.append("\(tap == .cghidEventTap ? "hid" : "session") \(event.getIntegerValueField(.keyboardEventKeycode))")
            },
            sleep: { microseconds in log.append("sleep \(microseconds)") }
        )

        let posted = await poster.post(SyntheticKeyEvent.commandChord(keyCode: 9, timing: .local), options: Self.markedChord)

        #expect(posted)
        #expect(log.entries == ["hid 55", "sleep 8000", "hid 9", "sleep 8000", "hid 9", "sleep 10000", "hid 55", "sleep 8000"])
    }

    @Test("when one event cannot be created, none is posted")
    func factoryFailure() async {
        let log = EventLog()
        let poster = CGEventKeyPoster(
            postEvent: { _, _ in log.append("post") },
            sleep: { _ in },
            eventFactory: { source, keyCode, keyDown in
                keyCode == 9 && !keyDown ? nil : CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            }
        )

        let posted = await poster.post(SyntheticKeyEvent.commandChord(keyCode: 9, timing: .local), options: Self.markedChord)

        #expect(!posted)
        #expect(log.entries.isEmpty)
    }

    @Test("hidden defaults pick the tap, the source and the flags-only fallback")
    func settings() throws {
        let suite = "pavarotti.tests.keyboard.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SyntheticKeyboardSettings.load(from: defaults) == SyntheticKeyboardSettings())

        defaults.set(false, forKey: "syntheticPasteChordEnabled")
        defaults.set("session", forKey: "syntheticKeyEventTap")
        defaults.set("combined", forKey: "syntheticKeyEventSourceState")
        let settings = SyntheticKeyboardSettings.load(from: defaults)
        #expect(!settings.chordEnabled)
        #expect(settings.eventTap == .session)
        #expect(settings.sourceState == .combinedSessionState)

        defaults.set("bogus", forKey: "syntheticKeyEventTap")
        #expect(SyntheticKeyboardSettings.load(from: defaults).eventTap == .hid)
    }
}

/// Collects lines from the posting queue.
private final class EventLog: Sendable {
    private let lines = Mutex<[String]>([])

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    var entries: [String] {
        lines.withLock { $0 }
    }
}
