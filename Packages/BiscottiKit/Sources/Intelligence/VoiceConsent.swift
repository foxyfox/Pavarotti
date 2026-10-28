import DataStore
import Foundation

/// Pavarotti: whose voice may recognize them in later meetings. Like the TypeWhisper
/// fork, another person's voice counts only once their consent is noted; the note keeps
/// when it was given. Stored in user defaults, keyed by person.
public final class VoiceConsentStore: @unchecked Sendable {
    public static let defaultsKey = "pavarotti.voiceConsents"
    /// Thread-safe, which makes the store `Sendable`.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// When consent was noted for `personID`, or `nil` without consent.
    public func consentDate(for personID: UUID) -> Date? {
        notes()[personID.uuidString]
    }

    /// Notes consent for `personID` at `date`, or removes the note.
    public func setConsent(_ given: Bool, for personID: UUID, at date: Date = Date()) {
        var current = notes()
        current[personID.uuidString] = given ? date : nil
        defaults.set(current, forKey: Self.defaultsKey)
    }

    /// Everyone with a consent note.
    public func consentedPersonIDs() -> Set<UUID> {
        Set(notes().keys.compactMap(UUID.init(uuidString:)))
    }

    private func notes() -> [String: Date] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: Date] ?? [:]
    }
}

// TODO: Learn the user's own voice from dictations too, as the TypeWhisper fork did (plan
// step 11). That needs the speaker model to embed a dictation clip, tested on the Mac; until
// then the user names themselves once, and the calendar or the voice from TypeWhisper
// marks them.

/// Pavarotti: keeps voice matching to the people it may recognize.
enum VoiceConsentFilter {
    /// The people whose voices may name speakers: those with a consent note and the
    /// user, as the calendar marks them. The user found by the voice from TypeWhisper
    /// joins in `VoiceprintEvidence`.
    static func allowedPersonIDs(consent: VoiceConsentStore, store: DataStore) async -> Set<UUID> {
        let user = await (try? store.read { store in
            try Set(store.fetchAllSnapshots().compactMap(\.currentUserPersonID))
        }) ?? []
        return consent.consentedPersonIDs().union(user)
    }

    /// The corpus with the tags of everyone else removed: their voices stay unknown.
    static func corpus(_ corpus: VoiceprintCorpusData, allowing allowed: Set<UUID>) -> VoiceprintCorpusData {
        let entries = corpus.entries.map { entry -> VoiceprintData in
            guard let tag = entry.tag, !allowed.contains(tag.personID) else { return entry }
            return VoiceprintData(
                meetingID: entry.meetingID, meetingTitle: entry.meetingTitle, meetingDate: entry.meetingDate,
                transcriptID: entry.transcriptID, speakerID: entry.speakerID,
                vector: entry.vector, speakingDuration: entry.speakingDuration, tag: nil
            )
        }
        return VoiceprintCorpusData(
            kind: corpus.kind, space: corpus.space,
            entries: entries, people: corpus.people.filter { allowed.contains($0.key) }
        )
    }
}
