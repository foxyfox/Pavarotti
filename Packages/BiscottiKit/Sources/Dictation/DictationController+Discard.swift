import Foundation

// Pavarotti: Escape discards a running dictation.
public extension DictationController {
    /// Whether a dictation is listening or transcribing, the time Escape discards it.
    var isDictating: Bool {
        phase == .listening || phase == .transcribing
    }

    /// Drops the running dictation: the audio is thrown away, nothing is transcribed
    /// or pasted, and the bubble closes. Does nothing when no dictation runs.
    func discard() {
        guard isDictating else { return }
        cancel()
    }
}
