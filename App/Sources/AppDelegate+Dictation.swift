import AppCore
import Dictation
import DictationUI

// Pavarotti: push-to-talk dictation, kept out of AppDelegate's body so the fork
// touches upstream's file in as few lines as possible.
extension AppDelegate {
    /// Starts dictation: takes over TypeWhisper's setup at the first launch, loads the
    /// Cohere model when it is installed, watches the shortcut and shows the indicator
    /// while listening.
    @MainActor
    func startDictation(on appCore: AppCore) {
        let runtime = DictationRuntime.live()
        appCore.dictation = runtime.controller
        runtime.controller.importFromTypeWhisperOnce()
        runtime.activate()
        let indicator = DictationIndicator(controller: runtime.controller)
        indicator.start()
        dictation = runtime
        dictationIndicator = indicator
    }
}
