import Foundation
import Observation

/// The live dictation setup the app starts at launch: the controller with real
/// microphone, Cohere engine, clipboard, sounds and volume, plus the shortcut monitor.
@MainActor
public final class DictationRuntime {
    public let controller: DictationController
    private let shortcuts: ShortcutMonitor
    private let escape = EscapeKeyMonitor()
    private var trustPolling: Task<Void, Never>?

    public init(controller: DictationController, shortcuts: ShortcutMonitor = ShortcutMonitor()) {
        self.controller = controller
        self.shortcuts = shortcuts
    }

    public static func live() -> DictationRuntime {
        let trust = SystemAccessibilityTrust()
        let library = SoundLibrary.standard
        let dependencies = DictationDependencies(
            audio: MicrophoneRecorder(),
            engine: CohereDictationEngine.shared,
            inserter: PasteboardTextInserter(trust: trust),
            sounds: SoundCuePlayer(library: library),
            ducker: SystemOutputDucker(),
            accessibility: trust,
            soundLibrary: library,
            dictionary: PersonalDictionary(fileURL: PersonalDictionary.standardFileURL),
            corrections: CorrectionWatcher(reader: AccessibilityFocusedTextReader(), signals: CommitKeyMonitor()),
            microphones: SystemMicrophones(),
            history: DictationHistory(fileURL: DictationHistory.standardFileURL)
        )
        return DictationRuntime(controller: DictationController(store: DictationSettingsStore(), dependencies: dependencies))
    }

    /// Loads the model, starts watching the shortcut and waits for Accessibility access.
    public func activate() {
        shortcuts.onEvent = { [weak self] event in
            self?.controller.handle(event)
        }
        controller.onShortcutConfigurationChange = { [weak self] in
            self?.refreshShortcut()
        }
        escape.onEscape = { [weak self] in
            self?.controller.discard()
        }
        controller.activate()
        refreshShortcut()
        followDictating()
        pollAccessibilityUntilTrusted()
    }

    /// Holds Escape only while a dictation runs, so it can be discarded.
    private func followDictating() {
        let dictating = withObservationTracking {
            controller.isDictating
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.followDictating()
            }
        }
        escape.setActive(dictating)
    }

    /// Re-installs the monitor for the current shortcut. Global key monitors only
    /// receive events once Accessibility access is granted, so this also runs then.
    private func refreshShortcut() {
        let settings = controller.settings
        shortcuts.install(settings.isEnabled ? settings.shortcut : nil)
    }

    /// Access is granted in System Settings, which does not tell the app. Check every
    /// two seconds until it is there.
    private func pollAccessibilityUntilTrusted() {
        trustPolling?.cancel()
        trustPolling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !controller.isAccessibilityTrusted else { return }
                controller.refreshAccessibility()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
