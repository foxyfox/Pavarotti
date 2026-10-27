import AppKit
import DesignSystem
import Dictation
import SwiftUI

/// Shows the dictation shortcut and records a new one when clicked: a modifier key
/// pressed and released on its own, or a key together with modifiers.
struct ShortcutRecorderRow: View {
    let controller: DictationController
    @State private var isRecording = false
    @State private var recorder: ShortcutRecorder?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("Shortcut")
                if let hint {
                    Text(hint)
                        .font(Tokens.metadataFont)
                        .foregroundStyle(Tokens.secondaryText)
                }
            }
            Spacer()
            Button(isRecording ? "Press the new shortcut\u{2026}" : controller.settings.shortcut.displayName) {
                if isRecording {
                    finishRecording()
                } else {
                    startRecording()
                }
            }
            .buttonStyle(.bordered)
        }
        .onDisappear { finishRecording() }
    }

    private var hint: String? {
        if isRecording {
            return "Press a modifier key on its own, or a key with \u{2318} \u{2325} \u{2303} or \u{21E7}. Esc cancels."
        }
        if controller.settings.shortcut == .modifier(.function) {
            return "Set \u{201C}Press \u{1F310} key to\u{201D} to \u{201C}Do Nothing\u{201D} in System Settings \u{2192} Keyboard."
        }
        return nil
    }

    private func startRecording() {
        isRecording = true
        controller.isCapturingShortcut = true
        let active = ShortcutRecorder()
        recorder = active
        active.start { shortcut in
            if let shortcut {
                controller.update { $0.shortcut = shortcut }
            }
            finishRecording()
        }
    }

    private func finishRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        controller.isCapturingShortcut = false
    }
}

/// Listens to the keyboard while the shortcut button is recording.
@MainActor
final class ShortcutRecorder {
    private var monitor: Any?
    private var pendingModifier: ModifierKey?

    /// Calls `onFinish` with the recorded shortcut, or `nil` when Esc cancelled.
    func start(onFinish: @escaping @MainActor (DictationShortcut?) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .flagsChanged:
                if let shortcut = modifierReleased(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue) {
                    onFinish(shortcut)
                }
            case .keyDown:
                pendingModifier = nil
                switch keyPressed(event) {
                case .cancel: onFinish(nil)
                case let .record(shortcut): onFinish(shortcut)
                case .ignore: NSSound.beep()
                }
            default:
                return event
            }
            // Keep the keys away from the settings window while recording.
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        pendingModifier = nil
    }

    /// A modifier key that goes down and up without another key in between becomes
    /// the shortcut.
    private func modifierReleased(keyCode: UInt16, rawFlags: UInt) -> DictationShortcut? {
        guard let key = ModifierKey.key(forKeyCode: keyCode) else { return nil }
        if key.isHeld(inRawFlags: rawFlags) {
            pendingModifier = key
            return nil
        }
        guard pendingModifier == key else { return nil }
        pendingModifier = nil
        return .modifier(key)
    }

    private enum KeyOutcome {
        case cancel
        case record(DictationShortcut)
        /// A key that cannot be a shortcut without modifiers.
        case ignore
    }

    private func keyPressed(_ event: NSEvent) -> KeyOutcome {
        let modifiers = KeyModifiers(eventFlags: event.modifierFlags.rawValue)
        if event.keyCode == 53, modifiers.isEmpty {
            return .cancel
        }
        guard !modifiers.isEmpty || KeyLabels.isFunctionKey(event.keyCode) else {
            return .ignore
        }
        let label = Self.label(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
        return .record(.combination(keyCode: event.keyCode, modifiers: modifiers, keyLabel: label))
    }

    /// The typed character for letters and digits (so a German keyboard shows Z where
    /// it is), the fixed name for everything else.
    static func label(keyCode: UInt16, characters: String?) -> String {
        guard let character = characters?.uppercased(), character.count == 1,
              let scalar = character.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar)
        else {
            return KeyLabels.label(for: keyCode)
        }
        return character
    }
}
