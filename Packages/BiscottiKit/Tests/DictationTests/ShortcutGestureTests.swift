import Testing
@testable import Dictation

@Suite("ShortcutGesture")
struct ShortcutGestureTests {
    @Test("hold: press starts, release stops")
    func holdStartsAndStops() {
        var gesture = ShortcutGesture(mode: .hold)
        #expect(gesture.handle(.pressed, at: 0) == .start)
        #expect(gesture.handle(.released, at: 0.1) == .stop)
        #expect(gesture.handle(.pressed, at: 1) == .start)
    }

    @Test("toggle: release keeps listening, the next press stops")
    func toggleStopsOnSecondPress() {
        var gesture = ShortcutGesture(mode: .toggle)
        #expect(gesture.handle(.pressed, at: 0) == .start)
        #expect(gesture.handle(.released, at: 2) == nil)
        #expect(gesture.handle(.pressed, at: 5) == .stop)
        #expect(gesture.handle(.released, at: 5.1) == nil)
        #expect(gesture.handle(.pressed, at: 6) == .start)
    }

    @Test("hybrid: a short tap keeps listening until the next press")
    func hybridTapLatches() {
        var gesture = ShortcutGesture(mode: .hybrid)
        #expect(gesture.handle(.pressed, at: 0) == .start)
        #expect(gesture.handle(.released, at: 0.2) == nil)
        #expect(gesture.handle(.pressed, at: 3) == .stop)
        #expect(gesture.handle(.released, at: 3.1) == nil)
    }

    @Test("hybrid: a long press stops on release")
    func hybridHoldStopsOnRelease() {
        var gesture = ShortcutGesture(mode: .hybrid)
        #expect(gesture.handle(.pressed, at: 0) == .start)
        #expect(gesture.handle(.released, at: 0.35) == .stop)
    }

    @Test("key repeat sends no further commands")
    func keyRepeatIsIgnored() {
        var gesture = ShortcutGesture(mode: .hold)
        #expect(gesture.handle(.pressed, at: 0) == .start)
        #expect(gesture.handle(.pressed, at: 0.5) == nil)
        #expect(gesture.handle(.pressed, at: 0.6) == nil)
        #expect(gesture.handle(.released, at: 1) == .stop)
    }

    @Test("another key while held cancels the dictation")
    func interruptionCancels() {
        var gesture = ShortcutGesture(mode: .hybrid)
        #expect(gesture.handle(.pressed, at: 0) == .start)
        #expect(gesture.handle(.interrupted, at: 0.1) == .cancel)
        #expect(gesture.handle(.released, at: 0.2) == nil)
        #expect(gesture.handle(.pressed, at: 1) == .start)
    }

    @Test("interruptions while idle or latched do nothing")
    func interruptionWithoutHeldPressIsIgnored() {
        var gesture = ShortcutGesture(mode: .toggle)
        #expect(gesture.handle(.interrupted, at: 0) == nil)
        #expect(gesture.handle(.pressed, at: 1) == .start)
        #expect(gesture.handle(.released, at: 1.1) == nil)
        #expect(gesture.handle(.interrupted, at: 2) == nil)
    }

    @Test("reset forgets a latched dictation")
    func resetStartsOver() {
        var gesture = ShortcutGesture(mode: .toggle)
        #expect(gesture.handle(.pressed, at: 0) == .start)
        #expect(gesture.handle(.released, at: 0.1) == nil)
        gesture.reset()
        #expect(gesture.handle(.pressed, at: 1) == .start)
    }

    @Test("a release without a press does nothing")
    func strayReleaseIsIgnored() {
        var gesture = ShortcutGesture(mode: .hold)
        #expect(gesture.handle(.released, at: 0) == nil)
    }
}

@Suite("ModifierKeyTracker")
struct ModifierKeyTrackerTests {
    /// Device-independent Option bit plus the left and right Option bits.
    private let optionFlag: UInt = 1 << 19
    private let leftOption: UInt = 1 << 5
    private let rightOption: UInt = 1 << 6

    @Test("right Option is followed while left Option is held")
    func rightOptionWithLeftHeld() {
        var tracker = ModifierKeyTracker(key: .rightOption)
        #expect(tracker.flagsChanged(rawFlags: optionFlag | leftOption) == nil)
        #expect(tracker.flagsChanged(rawFlags: optionFlag | leftOption | rightOption) == .pressed)
        #expect(tracker.flagsChanged(rawFlags: optionFlag | leftOption) == .released)
        #expect(tracker.flagsChanged(rawFlags: 0) == nil)
    }

    @Test("the Globe key uses the function flag")
    func functionKey() {
        var tracker = ModifierKeyTracker(key: .function)
        #expect(tracker.flagsChanged(rawFlags: 1 << 23) == .pressed)
        #expect(tracker.keyDown() == .interrupted)
        #expect(tracker.flagsChanged(rawFlags: 0) == .released)
        #expect(tracker.keyDown() == nil)
    }

    @Test("repeated flag events with the same state report nothing")
    func unchangedFlags() {
        var tracker = ModifierKeyTracker(key: .rightCommand)
        #expect(tracker.flagsChanged(rawFlags: 1 << 20 | 1 << 4) == .pressed)
        #expect(tracker.flagsChanged(rawFlags: 1 << 20 | 1 << 4 | 1 << 17) == nil)
    }
}

@Suite("Shortcut keys")
struct ShortcutKeyTests {
    @Test("modifier flags map to Command, Option, Control and Shift")
    func modifiersFromEventFlags() {
        let flags: UInt = 1 << 20 | 1 << 17
        let modifiers = KeyModifiers(eventFlags: flags)
        #expect(modifiers == [.command, .shift])
        #expect(KeyModifiers(eventFlags: 1 << 19 | 1 << 18) == [.option, .control])
        #expect(KeyModifiers(eventFlags: 1 << 23).isEmpty)
    }

    @Test("symbols follow the menu order")
    func symbolOrder() {
        let all: KeyModifiers = [.command, .shift, .option, .control]
        #expect(all.symbols == "\u{2303}\u{2325}\u{21E7}\u{2318}")
    }

    @Test("Carbon flags match cmdKey, shiftKey, optionKey and controlKey")
    func carbonFlags() {
        #expect(KeyModifiers.command.carbonFlags == 0x0100)
        #expect(KeyModifiers.shift.carbonFlags == 0x0200)
        #expect(KeyModifiers.option.carbonFlags == 0x0800)
        #expect(KeyModifiers.control.carbonFlags == 0x1000)
    }

    @Test("display names")
    func displayNames() {
        #expect(DictationShortcut.standard.displayName == "Fn / Globe")
        let combination = DictationShortcut.combination(keyCode: 2, modifiers: [.option, .command], keyLabel: "D")
        #expect(combination.displayName == "\u{2325}\u{2318}D")
    }

    @Test("key labels and function keys")
    func keyLabels() {
        #expect(KeyLabels.label(for: 2) == "D")
        #expect(KeyLabels.label(for: 122) == "F1")
        #expect(KeyLabels.label(for: 200) == "Key 200")
        #expect(KeyLabels.isFunctionKey(96))
        #expect(!KeyLabels.isFunctionKey(2))
    }

    @Test("modifier keys are found by key code")
    func modifierKeyLookup() {
        #expect(ModifierKey.key(forKeyCode: 61) == .rightOption)
        #expect(ModifierKey.key(forKeyCode: 63) == .function)
        #expect(ModifierKey.key(forKeyCode: 57) == nil)
    }
}
