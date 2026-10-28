import AppKit

/// Pavarotti: asks before the menu bar throws a recording away. A menu cannot show a
/// SwiftUI dialog, so this is an alert of its own.
enum DiscardRecordingAlert {
    @MainActor
    static func confirm() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard this recording?")
        alert.informativeText = String(localized: "The recording stops and is deleted with its notes. Nothing is transcribed.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Discard Recording"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
