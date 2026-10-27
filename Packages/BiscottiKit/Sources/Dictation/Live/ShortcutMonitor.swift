import AppKit
import Carbon.HIToolbox

/// Watches the keyboard for the dictation shortcut and reports presses and releases.
///
/// A single modifier key (Fn, right ⌥ …) is followed with global and local
/// `NSEvent` monitors, which need Accessibility access. A key combination is
/// registered as a Carbon hot key, which needs no permission and keeps the
/// keystroke from reaching the focused app.
@MainActor
public final class ShortcutMonitor {
    public var onEvent: (@MainActor (ShortcutEvent) -> Void)?

    private var eventMonitors: [Any] = []
    private var tracker: ModifierKeyTracker?
    private var hotKey: CarbonHotKey?

    public init() {}

    /// Starts watching `shortcut`, replacing what was watched before. `nil` stops watching.
    public func install(_ shortcut: DictationShortcut?) {
        remove()
        switch shortcut {
        case let .modifier(key):
            watchModifier(key)
        case let .combination(keyCode, modifiers, _):
            let carbonKey = CarbonHotKey { [weak self] event in
                self?.onEvent?(event)
            }
            if carbonKey.register(keyCode: UInt32(keyCode), modifiers: modifiers.carbonFlags) {
                hotKey = carbonKey
            }
        case nil:
            break
        }
    }

    public func remove() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors = []
        tracker = nil
        hotKey?.unregister()
        hotKey = nil
    }

    private func watchModifier(_ key: ModifierKey) {
        tracker = ModifierKeyTracker(key: key)
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        eventMonitors = [global, local].compactMap(\.self)
    }

    private func handle(_ event: NSEvent) {
        // Pavarotti's own paste chord holds Command, which must not count as the shortcut.
        guard event.cgEvent.map(SyntheticKeyboardMarker.isPasteShortcut) != true,
              let shortcutEvent = nextEvent(type: event.type, rawFlags: event.modifierFlags.rawValue)
        else {
            return
        }
        onEvent?(shortcutEvent)
    }

    private func nextEvent(type: NSEvent.EventType, rawFlags: UInt) -> ShortcutEvent? {
        switch type {
        case .flagsChanged: tracker?.flagsChanged(rawFlags: rawFlags)
        case .keyDown: tracker?.keyDown()
        default: nil
        }
    }
}

/// A Carbon hot key that reports both press and release, for push to talk.
@MainActor
final class CarbonHotKey {
    /// 'PAVT'. Upstream's ⌘⇧R hot key uses its own signature and small IDs.
    fileprivate static let signature = OSType(0x5041_5654)
    fileprivate static var registered: [UInt32: CarbonHotKey] = [:]
    /// Starts far above the IDs upstream's `GlobalHotKey` hands out.
    private static var nextID = UInt32(0x5041_0000)

    private let handler: @MainActor (ShortcutEvent) -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var identifier: UInt32 = 0

    init(handler: @escaping @MainActor (ShortcutEvent) -> Void) {
        self.handler = handler
    }

    /// Registers the key with Carbon modifiers. Returns false when macOS refused it,
    /// for example because another app owns the combination.
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        identifier = Self.nextID
        Self.nextID &+= 1
        Self.registered[identifier] = self

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            dictationHotKeyCallback,
            2,
            &eventTypes,
            nil,
            &handlerRef
        )
        guard installed == noErr else {
            unregister()
            return false
        }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        handlerRef = nil
        Self.registered.removeValue(forKey: identifier)
    }

    fileprivate func fire(_ event: ShortcutEvent) {
        handler(event)
    }
}

/// Routes Carbon hot key events to the matching `CarbonHotKey`. Events of other
/// hot keys (such as upstream's record shortcut) are passed on untouched.
private func dictationHotKeyCallback(
    _: EventHandlerCallRef?,
    event: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let shortcutEvent: ShortcutEvent = GetEventKind(event) == UInt32(kEventHotKeyReleased) ? .released : .pressed
    let identifier = hotKeyID.id
    let signature = hotKeyID.signature
    // Carbon delivers hot key events on the main thread.
    let handled = MainActor.assumeIsolated {
        guard signature == CarbonHotKey.signature, let hotKey = CarbonHotKey.registered[identifier] else {
            return false
        }
        hotKey.fire(shortcutEvent)
        return true
    }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
