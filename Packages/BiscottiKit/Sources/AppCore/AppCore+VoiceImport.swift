import Foundation
import Intelligence
import os

/// Pavarotti: the voices of Andreas's TypeWhisper fork, taken over once at launch.
public extension AppCore {
    /// Starts what Pavarotti adds at launch: the meeting notes and, once, the voices from
    /// TypeWhisper. Called by the app, not by `onLaunch`, so tests never touch the user's
    /// notes folder or TypeWhisper's files.
    func startForkFeatures() async {
        await startMeetingNotes()
        await importTypeWhisperVoicesOnce()
    }

    /// Takes over TypeWhisper's voices the first time Pavarotti finds them and logs what
    /// was taken over, with how close each voice is to the speakers named in Pavarotti.
    func importTypeWhisperVoicesOnce(defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: Self.checkedTypeWhisperVoicesKey) else { return }
        defaults.set(true, forKey: Self.checkedTypeWhisperVoicesKey)
        guard let voices = intelligence.importedVoices else { return }
        let logger = Logger(subsystem: "de.foxagon.pavarotti", category: "TypeWhisperImport")
        do {
            let outcome = try await TypeWhisperVoiceImport.run(
                store: store, consent: intelligence.voiceConsent, voices: voices
            )
            let similarities = outcome.comparisons.map { String(format: "%.2f", $0.similarity) }
            logger.info("""
            Voices: \(outcome.people.count, privacy: .public) people, own voice \(outcome.ownVoice, privacy: .public), \
            similarity to named speakers \(similarities.joined(separator: ", "), privacy: .public)
            """)
            logger.info("Voices: \(outcome.summary, privacy: .private)")
        } catch {
            logger.error("Voices could not be read: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The second version also logs the similarity numbers, so installs that ran the first
    /// one take the voices over once more.
    private static let checkedTypeWhisperVoicesKey = "pavarotti.voices.checkedTypeWhisper.2"
}
