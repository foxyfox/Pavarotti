import DataStore
import Foundation
import Testing
@testable import Intelligence

/// Pavarotti: other people's voices name speakers only with a consent note.
@Suite("Voice consent")
struct VoiceConsentTests {
    private static func makeConsent() throws -> VoiceConsentStore {
        let defaults = try #require(UserDefaults(suiteName: "VoiceConsentTests.\(UUID().uuidString)"))
        return VoiceConsentStore(defaults: defaults)
    }

    private static func entry(_ speakerID: Int, person: UUID?) -> VoiceprintData {
        VoiceprintData(
            meetingID: UUID(), meetingTitle: "Sync", meetingDate: Date(timeIntervalSince1970: 1_760_000_000),
            transcriptID: UUID(), speakerID: speakerID, vector: [0.1, 0.2], speakingDuration: 30,
            tag: person.map { SpeakerTagData(personID: $0, userSet: true) }
        )
    }

    @Test("A consent note keeps its date and can be removed")
    func notes() throws {
        let consent = try Self.makeConsent()
        let laura = UUID()
        let noted = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(consent.consentDate(for: laura) == nil)

        consent.setConsent(true, for: laura, at: noted)
        #expect(consent.consentDate(for: laura) == noted)
        #expect(consent.consentedPersonIDs() == [laura])

        consent.setConsent(false, for: laura)
        #expect(consent.consentDate(for: laura) == nil)
        #expect(consent.consentedPersonIDs().isEmpty)
    }

    @Test("Voices without consent stay in the corpus, but unnamed")
    func filter() {
        let laura = UUID()
        let petra = UUID()
        let corpus = VoiceprintCorpusData(
            kind: .raw, space: "space",
            entries: [Self.entry(0, person: laura), Self.entry(1, person: petra), Self.entry(2, person: nil)],
            people: [
                laura: PersonData(id: laura, name: "Laura", email: nil),
                petra: PersonData(id: petra, name: "Petra", email: nil)
            ]
        )

        let filtered = VoiceConsentFilter.corpus(corpus, allowing: [laura])

        #expect(filtered.entries.map(\.tag?.personID) == [laura, nil, nil])
        #expect(filtered.entries.map(\.speakerID) == [0, 1, 2])
        #expect(Set(filtered.people.keys) == [laura])
    }

    @Test("The user, as the calendar marks them, always counts")
    func userCounts() async throws {
        let store = try DataStore(storage: .inMemory)
        let consent = try Self.makeConsent()
        let laura = UUID()
        consent.setConsent(true, for: laura)

        let meetingID = try await store.createMeeting(title: "Sync")
        try await store.setSnapshot(CalendarSnapshot(compositeKey: "sync|key", title: "Sync"), for: meetingID)
        let user = try await store.findOrCreatePerson(name: "Andreas", email: "andreas@example.com")
        try await store.setParticipants([user], organizer: nil, currentUser: user, for: meetingID)

        let allowed = await VoiceConsentFilter.allowedPersonIDs(consent: consent, store: store)
        #expect(allowed == [laura, user])
    }
}
