import Foundation
import Intelligence

/// Pavarotti: the voices of Andreas's TypeWhisper fork, taken over once at launch and
/// again from Settings.
public extension AppCore {
    /// Starts what Pavarotti adds at launch: the meeting notes and, once, the voices from
    /// TypeWhisper. Called by the app, not by `onLaunch`, so tests never touch the user's
    /// notes folder or TypeWhisper's files.
    func startForkFeatures() async {
        await startMeetingNotes()
        await importTypeWhisperVoices(force: false)
    }

    /// Takes over TypeWhisper's voices. At launch this runs once; `force` (the button in
    /// Settings) runs it again and replaces the voices taken over before.
    /// - Returns: What was taken over, for the Settings caption.
    @discardableResult
    func importTypeWhisperVoices(force: Bool, defaults: UserDefaults = .standard) async -> String {
        guard force || !defaults.bool(forKey: Self.checkedTypeWhisperVoicesKey) else { return "" }
        defaults.set(true, forKey: Self.checkedTypeWhisperVoicesKey)
        guard let voices = intelligence.importedVoices else { return "" }
        do {
            let outcome = try await TypeWhisperVoiceImport.run(
                store: store, consent: intelligence.voiceConsent, voices: voices
            )
            return outcome.summary
        } catch {
            return "TypeWhisper\u{2019}s voices could not be read: \(error.localizedDescription)"
        }
    }

    /// The voices taken over from TypeWhisper.
    var importedVoices: [ImportedVoice] {
        intelligence.importedVoices?.load() ?? []
    }

    /// Forgets the voices taken over from TypeWhisper. Names and consents stay.
    func removeImportedVoices() throws {
        try intelligence.importedVoices?.removeAll()
    }

    private static let checkedTypeWhisperVoicesKey = "pavarotti.voices.checkedTypeWhisper"
}
