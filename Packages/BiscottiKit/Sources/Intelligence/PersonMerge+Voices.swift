import DataStore
import Foundation

// MARK: - Pavarotti: voices and consents follow a merged person

public extension VoiceConsentStore {
    /// Gives the consent of `merge`'s source to its target, unless the target has its own,
    /// and removes the source's note.
    func follow(_ merge: PersonMerge) {
        guard let date = consentDate(for: merge.sourceID) else { return }
        if consentDate(for: merge.targetID) == nil {
            setConsent(true, for: merge.targetID, at: date)
        }
        setConsent(false, for: merge.sourceID)
    }
}

public extension ImportedVoiceStore {
    /// Gives the voices imported for `merge`'s source to its target.
    func follow(_ merge: PersonMerge) throws {
        let voices = load()
        guard voices.contains(where: { $0.personID == merge.sourceID }) else { return }
        try save(voices.map { voice in
            guard voice.personID == merge.sourceID else { return voice }
            return ImportedVoice(
                id: voice.id, personID: merge.targetID, name: voice.name, vector: voice.vector,
                model: voice.model, samples: voice.samples, speechSeconds: voice.speechSeconds,
                updatedAt: voice.updatedAt
            )
        })
    }
}
