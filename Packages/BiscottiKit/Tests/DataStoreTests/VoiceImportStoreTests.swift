import DataStore
import Foundation
import Testing

/// Pavarotti: the store queries behind taking over TypeWhisper's voices.
@Suite("Voice import queries")
struct VoiceImportStoreTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    @Test("A name finds the person with exactly that name, ignoring case and accents")
    func exactName() async throws {
        let store = try makeStore()
        let rene = try await store.findOrCreatePerson(name: "René Weber", email: nil)
        _ = try await store.findOrCreatePerson(name: "Rene", email: nil)

        #expect(try await store.personID(matchingName: " rene weber ") == rene)
    }

    @Test("Of several people with the same name, the calendar's one with an email wins")
    func sameNamePrefersEmail() async throws {
        let store = try makeStore()
        _ = try await store.findOrCreatePerson(name: "Laura", email: nil)
        let calendar = try await store.findOrCreatePerson(name: "Laura", email: "laura@example.com")

        #expect(try await store.personID(matchingName: "Laura") == calendar)
    }

    @Test("A first name finds the only person with it and nobody when several share it")
    func firstName() async throws {
        let store = try makeStore()
        let laura = try await store.findOrCreatePerson(name: "Laura Schmidt", email: "laura@example.com")
        _ = try await store.findOrCreatePerson(name: "Tom Berg", email: nil)
        _ = try await store.findOrCreatePerson(name: "Tom Kraus", email: nil)

        #expect(try await store.personID(matchingName: "laura") == laura)
        #expect(try await store.personID(matchingName: "Tom") == nil)
        #expect(try await store.personID(matchingName: "Laura Meier") == nil)
        #expect(try await store.personID(matchingName: " ") == nil)
    }

    @Test("The user is whoever the calendar marks in the most meetings")
    func mostFrequentUser() async throws {
        let store = try makeStore()
        #expect(try await store.mostFrequentCurrentUserPersonID() == nil)

        let work = try await store.findOrCreatePerson(name: "Andreas", email: "andreas@work.example")
        let home = try await store.findOrCreatePerson(name: "Andreas", email: "andreas@home.example")
        for (index, user) in [work, home, work].enumerated() {
            let meetingID = try await store.createMeeting(title: "Meeting \(index)")
            try await store.setSnapshot(CalendarSnapshot(compositeKey: "m\(index)|key", title: "Meeting"), for: meetingID)
            try await store.setParticipants([user], organizer: nil, currentUser: user, for: meetingID)
        }

        #expect(try await store.mostFrequentCurrentUserPersonID() == work)
    }

    @Test("People are looked up by ID, leaving out the ones that are gone")
    func peopleByID() async throws {
        let store = try makeStore()
        let laura = try await store.findOrCreatePerson(name: "Laura", email: "laura@example.com")

        let people = try await store.people(ids: [laura, UUID()])

        #expect(people == [laura: PersonData(id: laura, name: "Laura", email: "laura@example.com")])
    }
}
