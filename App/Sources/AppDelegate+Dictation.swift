import AppCore
import Dictation
import DictationUI

// Pavarotti: push-to-talk dictation, kept out of AppDelegate's body so the fork
// touches upstream's file in as few lines as possible.
extension AppDelegate {
    /// Starts dictation: loads the Cohere model when it is installed, watches the
    /// shortcut and shows the indicator while listening.
    func startDictation(on appCore: AppCore) {
        let runtime = DictationRuntime.live()
        appCore.dictation = runtime.controller
        runtime.activate()
        let indicator = DictationIndicator(controller: runtime.controller)
        indicator.start()
        dictation = runtime
        dictationIndicator = indicator
    }
}
