import Carbon.HIToolbox

/// Catches Escape while a dictation runs, so it can be discarded.
///
/// Escape is registered as a Carbon hot key only for that time. That needs no
/// permission, keeps the press from also reaching the focused app (where it might
/// close a dialog), and leaves Escape alone the rest of the time.
@MainActor
final class EscapeKeyMonitor {
    var onEscape: (@MainActor () -> Void)?

    private var hotKey: CarbonHotKey?

    var isActive: Bool {
        hotKey != nil
    }

    /// Registers Escape (`true`) or gives it back to the system (`false`).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        guard active else {
            hotKey?.unregister()
            hotKey = nil
            return
        }
        let key = CarbonHotKey { [weak self] event in
            guard event == .pressed else { return }
            self?.onEscape?()
        }
        if key.register(keyCode: UInt32(kVK_Escape), modifiers: 0) {
            hotKey = key
        }
    }
}
