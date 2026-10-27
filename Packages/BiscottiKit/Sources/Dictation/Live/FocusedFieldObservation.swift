import AppKit
import ApplicationServices

/// Reads the focused text field through Accessibility.
@MainActor
public final class AccessibilityFocusedTextReader: FocusedTextReading {
    /// Keeps a slow or hanging app from stalling dictation.
    private static let messagingTimeout: Float = 0.25

    public init() {}

    public func focusedText() -> FocusedText? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)
        // Attribute names spelled out: the kAX… constants are plain strings anyway.
        guard let element = Self.element(systemWide, "AXFocusedUIElement") else { return nil }
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        guard Self.string(element, "AXRole") != "AXSecureTextField",
              Self.string(element, "AXSubrole") != "AXSecureTextField",
              let value = Self.string(element, "AXValue")
        else {
            return nil
        }
        return FocusedText(field: AccessibilityField(element: element), value: value)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }
}

/// An Accessibility element compared the way Core Foundation compares it.
struct AccessibilityField: Hashable {
    let element: AXUIElement

    static func == (lhs: AccessibilityField, rhs: AccessibilityField) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// Return, keypad Enter and Tab.
private let commitKeyCodes: Set<UInt16> = [36, 76, 48]

/// Reports Return, Tab and switches to another app while a field is watched.
@MainActor
public final class CommitKeyMonitor: CommitSignalMonitoring {
    private var keyMonitor: Any?
    private var activationObserver: (any NSObjectProtocol)?

    public init() {}

    public func start(onCommit: @escaping @MainActor @Sendable () -> Void) {
        stop()
        // Global monitors see other apps' keys only, which is all that matters here.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if commitKeyCodes.contains(event.keyCode) {
                onCommit()
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                onCommit()
            }
        }
    }

    public func stop() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }
}
