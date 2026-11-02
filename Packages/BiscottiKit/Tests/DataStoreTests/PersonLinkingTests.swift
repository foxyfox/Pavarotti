import Foundation
import Testing
import Transcription
@testable import DataStore

/// Pavarotti: the calendar's people and the people the user named are one person.
@Suite("Person linking")
struct PersonLinkingTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    /// Inserts a person as is, the way the store held duplicates before linking.
    private func insertPerson(_ store: DataStore, name: String, email: String?) async throws -> UUID {
        try await store.read { store in
            let person = Person(name: name, email: email)
            store.context.insert(person)
            try store.save()
            return person.id
        }
    }

    private func person(_ store: DataStore, _ id: UUID) async throws -> PersonData? {
        try await store.people(ids: [id])[id]
    }

    private func addTranscript(_ store: DataStore, to meetingID: UUID) async throws -> UUID {
        let segment = TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0", startTime: 0, endTime: 5,
            text: "Hallo", confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let result = TranscriptResult(
            transcriptionMethodId: "v1", language: "de", speakerCount: 1,
            segments: [segment], processingDuration: 1
        )
        let transcriptID = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setPreferredTranscript(transcriptID, for: meetingID)
        return transcriptID
    }

    // MARK: - Names

    @Test("An address with first and last name gives a name; others give none")
    func nameFromEmail() {
        #expect(PersonNames.name(fromEmail: "max.mustermann@firma.de") == "Max Mustermann")
        #expect(PersonNames.name(fromEmail: "MAX_MUELLER+meet@firma.de") == "Max Mueller")
        #expect(PersonNames.name(fromEmail: "max-otto.mustermann@firma.de") == "Max Otto Mustermann")
        #expect(PersonNames.name(fromEmail: "info@firma.de") == nil)
        #expect(PersonNames.name(fromEmail: "m.mustermann@firma.de") == nil)
        #expect(PersonNames.name(fromEmail: "max.mustermann") == nil)
    }

    @Test("A participant without a name shows the one from the address")
    func displayName() {
        #expect(PersonNames.displayName(name: "Max Mustermann", email: "mm@firma.de") == "Max Mustermann")
        #expect(PersonNames.displayName(name: nil, email: "max.mustermann@firma.de") == "Max Mustermann")
        #expect(PersonNames.displayName(name: "max.mustermann@firma.de", email: "max.mustermann@firma.de") == "Max Mustermann")
        #expect(PersonNames.displayName(name: nil, email: "info@firma.de") == "info@firma.de")
        #expect(PersonNames.displayName(name: nil, email: nil) == "Unknown")
    }

    @Test("Full names compare across case, accents, umlauts and 'Last, First'")
    func matchKeys() {
        let mueller = PersonNames.matchKeys("Max Müller")
        #expect(!mueller.isDisjoint(with: PersonNames.matchKeys("max mueller")))
        #expect(!mueller.isDisjoint(with: PersonNames.matchKeys("Müller, Max")))
        #expect(!PersonNames.matchKeys("René Weber").isDisjoint(with: PersonNames.matchKeys("Rene Weber")))
        #expect(PersonNames.matchKeys("Max").isEmpty)
        #expect(PersonNames.matchKeys("max@firma.de").isEmpty)
        #expect(PersonNames.matchKeys("Max Müller").isDisjoint(with: PersonNames.matchKeys("Max Meier")))
    }

    // MARK: - Calendar participants

    @Test("A calendar participant joins the named person with the same full name")
    func calendarJoinsNamedPerson() async throws {
        let store = try makeStore()
        let named = try await store.findOrCreatePerson(name: "Max Müller", email: nil)

        let fromCalendar = try await store.findOrCreatePerson(name: "Müller, Max", email: "mm@firma.de")
        let fromAddress = try await store.findOrCreatePerson(name: "Max Mueller", email: "mm@firma.de")

        #expect(fromCalendar == named)
        #expect(fromAddress == named)
        let person = try await person(store, named)
        #expect(person?.name == "Max Müller")
        #expect(person?.email == "mm@firma.de")
    }

    @Test("The name in the address is enough to join")
    func addressJoinsNamedPerson() async throws {
        let store = try makeStore()
        let named = try await store.findOrCreatePerson(name: "Max Müller", email: nil)
        let name = PersonNames.displayName(name: nil, email: "max.mueller@firma.de")

        #expect(try await store.findOrCreatePerson(name: name, email: "max.mueller@firma.de") == named)
    }

    @Test("A second address of a known full name finds the same person")
    func secondAddress() async throws {
        let store = try makeStore()
        let work = try await store.findOrCreatePerson(name: "Max Müller", email: "max@work.de")

        #expect(try await store.findOrCreatePerson(name: "Max Müller", email: "max@home.de") == work)
        #expect(try await person(store, work)?.email == "max@work.de")
    }

    @Test("First names alone and ambiguous names stay apart")
    func vagueNamesStayApart() async throws {
        let store = try makeStore()
        let max = try await store.findOrCreatePerson(name: "Max", email: nil)
        let calendarMax = try await store.findOrCreatePerson(name: "Max", email: "max@firma.de")
        #expect(max != calendarMax)

        _ = try await insertPerson(store, name: "Tom Berg", email: nil)
        _ = try await insertPerson(store, name: "Tom Berg", email: nil)
        let calendarTom = try await store.findOrCreatePerson(name: "Tom Berg", email: "tom@firma.de")
        #expect(try await person(store, calendarTom)?.email == "tom@firma.de")
        #expect(try await store.allPersonData().count(where: { $0.name == "Tom Berg" }) == 3)
    }

    @Test("A name typed in another spelling finds the calendar's person")
    func typedNameFindsCalendarPerson() async throws {
        let store = try makeStore()
        let calendar = try await store.findOrCreatePerson(name: "Max Mueller", email: "mm@firma.de")

        #expect(try await store.findOrCreatePerson(name: "max müller", email: nil) == calendar)
    }

    // MARK: - Merging

    @Test("A merge moves meetings, organizer, user mark and speakers to the target")
    func mergeMovesEverything() async throws {
        let store = try makeStore()
        let named = try await insertPerson(store, name: "Max Müller", email: nil)
        let calendar = try await insertPerson(store, name: "mm@firma.de", email: "mm@firma.de")
        let other = try await store.findOrCreatePerson(name: "Eva", email: "eva@firma.de")

        let meetingID = try await store.createMeeting(title: "Sync")
        try await store.setSnapshot(CalendarSnapshot(compositeKey: "sync|key", title: "Sync"), for: meetingID)
        try await store.setParticipants([calendar, other], organizer: calendar, currentUser: calendar, for: meetingID)
        let transcriptID = try await addTranscript(store, to: meetingID)
        try await store.setSpeakerAssignment(speakerID: 0, personID: calendar, for: transcriptID)

        try await store.mergePerson(calendar, into: named)

        let people = try #require(try await store.meetingPeople(id: meetingID))
        #expect(people.organizer?.id == named)
        #expect(people.organizer?.name == "Max Müller")
        #expect(people.organizer?.email == "mm@firma.de")
        #expect(people.participants.map(\.id) == [other])
        let transcript = try await store.transcript(id: transcriptID)
        #expect(transcript?.speakerAssignments[0]?.id == named)
        #expect(try await store.mostFrequentCurrentUserPersonID() == named)
        #expect(try await store.people(ids: [calendar]).isEmpty)
    }

    @Test("A merge keeps the target's email and its own name")
    func mergeKeepsTarget() async throws {
        let store = try makeStore()
        let target = try await insertPerson(store, name: "Max", email: "max@work.de")
        let source = try await insertPerson(store, name: "Max Müller", email: "max@home.de")

        try await store.mergePerson(source, into: target)
        try await store.mergePerson(target, into: target)

        let person = try await person(store, target)
        #expect(person?.name == "Max")
        #expect(person?.email == "max@work.de")
    }

    @Test("Launch joins calendar duplicates into the named person and names address-only people")
    func linkExistingDuplicates() async throws {
        let store = try makeStore()
        let named = try await insertPerson(store, name: "Max Müller", email: nil)
        let calendar = try await insertPerson(store, name: "max.mueller@firma.de", email: "max.mueller@firma.de")
        let unnamed = try await insertPerson(store, name: "Unknown", email: "eva.schmidt@firma.de")
        let meetingID = try await store.createMeeting(title: "Sync")
        try await store.setParticipants([calendar, unnamed], organizer: nil, for: meetingID)

        let merges = try await store.linkCalendarPeopleToNamedPeople()

        #expect(merges == [PersonMerge(sourceID: calendar, targetID: named)])
        let people = try #require(try await store.meetingPeople(id: meetingID))
        #expect(Set(people.participants.map(\.id)) == [named, unnamed])
        #expect(try await person(store, named)?.email == "max.mueller@firma.de")
        #expect(try await person(store, unnamed)?.name == "Eva Schmidt")
        #expect(try await store.linkCalendarPeopleToNamedPeople().isEmpty)
    }
}
