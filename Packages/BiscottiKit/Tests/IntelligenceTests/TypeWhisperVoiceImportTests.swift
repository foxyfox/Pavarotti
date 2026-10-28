import DataStore
import Foundation
import Testing
import Transcription
import VoiceprintMatching
@testable import Intelligence

/// Pavarotti: voices taken over from TypeWhisper's `speaker-profiles.json`.
@Suite("TypeWhisper voice import")
struct TypeWhisperVoiceImportTests {
    private let folder: URL
    private let profilesURL: URL
    private let voices: ImportedVoiceStore
    private let consent: VoiceConsentStore

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "voice-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        profilesURL = folder.appending(path: "speaker-profiles.json")
        voices = ImportedVoiceStore(fileURL: folder.appending(path: "Pavarotti/imported-voices.json"))
        let defaults = try #require(UserDefaults(suiteName: "TypeWhisperVoiceImportTests.\(UUID().uuidString)"))
        consent = VoiceConsentStore(defaults: defaults)
    }

    // MARK: - Helpers

    private static let lauraID = "0A1B2C3D-0000-4000-8000-000000000001"
    private static let lauraVoice: [Float] = [1, 0, 0, 0]
    private static let tomVoice: [Float] = [0, 1, 0, 0]
    private static let ownVoice: [Float] = [0, 0, 1, 0]

    private static func list(_ vector: [Float]) -> String {
        "[" + vector.map { String($0) }.joined(separator: ",") + "]"
    }

    /// A schema 2 file as TypeWhisper writes it: sorted keys, dates with milliseconds.
    private func writeProfiles(ownSeconds: Double = 42.5) throws {
        let json = """
        {"own":{"createdAt":"2026-10-01T08:00:00.000Z","dictationCount":12,"embedding":\(Self.list(Self.ownVoice)),\
        "embeddingModel":"FluidAudio WeSpeaker (df2625ac)","meetingCount":3,"meetingWeight":12,\
        "speechSeconds":\(ownSeconds),"updatedAt":"2026-10-20T09:30:00.250Z","weight":40},\
        "ownLearnedThrough":"2026-10-20T09:30:00.250Z",\
        "people":[{"consentDate":"2026-10-10T14:00:00.000Z","count":4,"embedding":\(Self.list(Self.lauraVoice)),\
        "embeddingModel":"FluidAudio WeSpeaker (df2625ac)","id":"\(Self.lauraID)","name":"Laura",\
        "recordings":["a","b"],"speechSeconds":310,"updatedAt":"2026-10-21T10:00:00.000Z","weight":120},\
        {"consentDate":"2026-10-12T14:00:00Z","count":1,"embedding":\(Self.list(Self.tomVoice)),\
        "embeddingModel":"FluidAudio WeSpeaker (df2625ac)","id":"not-a-uuid","name":" Tom Berg ",\
        "recordings":["c"],"speechSeconds":95,"updatedAt":"2026-10-12T15:00:00Z","weight":60}],\
        "schemaVersion":2}
        """
        try Data(json.utf8).write(to: profilesURL)
    }

    private func run(_ store: DataStore) async throws -> TypeWhisperVoiceImport.Outcome {
        try await TypeWhisperVoiceImport.run(fileURL: profilesURL, store: store, consent: consent, voices: voices)
    }

    private static func makeUser(in store: DataStore) async throws -> UUID {
        let meetingID = try await store.createMeeting(title: "Sync")
        try await store.setSnapshot(CalendarSnapshot(compositeKey: "sync|key", title: "Sync"), for: meetingID)
        let user = try await store.findOrCreatePerson(name: "Andreas Fuchs", email: "andreas@example.com")
        try await store.setParticipants([user], organizer: nil, currentUser: user, for: meetingID)
        return user
    }

    /// A meeting whose speaker 0 has `vector`, optionally named as `person` by the user.
    private static func makeMeeting(
        in store: DataStore, vector: [Float], person: UUID? = nil
    ) async throws -> (meetingID: UUID, transcriptID: UUID) {
        let meetingID = try await store.createMeeting(title: "Weekly")
        let segment = TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0", startTime: 0, endTime: 30,
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
        try await store.addVoiceprints(
            [NewVoiceprint(speakerID: 0, vector: vector, speakingDuration: 90)],
            kind: .raw, space: "pyannote-v4/W8A16", to: transcriptID
        )
        if let person {
            try await store.setSpeakerAssignment(speakerID: 0, personID: person, for: transcriptID)
        }
        return (meetingID, transcriptID)
    }

    // MARK: - Import

    @Test("People are matched by name or created, and their consent comes along")
    func importsPeople() async throws {
        let store = try DataStore(storage: .inMemory)
        let laura = try await store.findOrCreatePerson(name: "Laura Schmidt", email: "laura@example.com")
        try writeProfiles()

        let outcome = try await run(store)

        #expect(outcome.people == ["Laura", "Tom Berg"])
        #expect(outcome.ownVoice)
        #expect(!outcome.userKnown)
        let saved = voices.load()
        #expect(saved.map(\.name) == ["Laura", "Tom Berg", "You"])
        #expect(saved[0].personID == laura)
        #expect(saved[0].id == UUID(uuidString: Self.lauraID))
        #expect(saved[0].vector == Self.lauraVoice)
        #expect(saved[0].samples == 4)
        #expect(saved[2].personID == nil)
        #expect(saved[2].samples == 15)

        let tom = try #require(saved[1].personID)
        let created = try await store.people(ids: [tom])
        #expect(created[tom]?.name == "Tom Berg")
        #expect(consent.consentDate(for: laura) == Date(timeIntervalSince1970: 1_791_640_800))
        #expect(consent.consentedPersonIDs() == [laura, tom])
    }

    @Test("Importing again replaces the voices and keeps a consent noted in Pavarotti")
    func importAgain() async throws {
        let store = try DataStore(storage: .inMemory)
        let laura = try await store.findOrCreatePerson(name: "Laura", email: nil)
        let noted = Date(timeIntervalSince1970: 1_700_000_000)
        consent.setConsent(true, for: laura, at: noted)
        try writeProfiles()

        _ = try await run(store)
        _ = try await run(store)

        #expect(voices.load().count == 3)
        #expect(consent.consentDate(for: laura) == noted)
        let people = try await store.read { try $0.fetchAllPersons().count }
        #expect(people == 2)
    }

    @Test("An own voice with too little dictation is left out")
    func shortOwnVoice() async throws {
        let store = try DataStore(storage: .inMemory)
        try writeProfiles(ownSeconds: 6)

        let outcome = try await run(store)

        #expect(!outcome.ownVoice)
        #expect(voices.load().allSatisfy { $0.personID != nil })
    }

    @Test("Without TypeWhisper's file nothing is imported")
    func noFile() async throws {
        let store = try DataStore(storage: .inMemory)

        let outcome = try await run(store)

        #expect(!outcome.foundFile)
        #expect(outcome.summary == "TypeWhisper has no saved voices.")
        #expect(voices.load().isEmpty)
    }

    @Test("The import compares each voice with the speakers named as that person")
    func comparesWithNamedSpeakers() async throws {
        let store = try DataStore(storage: .inMemory)
        let laura = try await store.findOrCreatePerson(name: "Laura", email: nil)
        let user = try await Self.makeUser(in: store)
        _ = try await Self.makeMeeting(in: store, vector: [0.8, 0.6, 0, 0], person: laura)
        _ = try await Self.makeMeeting(in: store, vector: [0, 0, 1, 0], person: user)
        _ = try await Self.makeMeeting(in: store, vector: [0, 1, 0, 0])
        try writeProfiles()

        let outcome = try await run(store)

        #expect(outcome.userKnown)
        #expect(outcome.comparisons.map(\.name) == ["Laura", "you"])
        #expect(abs(outcome.comparisons[0].similarity - 0.8) < 0.0001)
        #expect(abs(outcome.comparisons[1].similarity - 1) < 0.0001)
        #expect(outcome.summary.contains("Laura 0.80, you 1.00"))
    }

    @Test("Imported voices are readable only by the user")
    func filePermissions() throws {
        try voices.save([])
        let attributes = try FileManager.default.attributesOfItem(atPath: voices.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try voices.removeAll()
        #expect(voices.load().isEmpty)
    }

    // MARK: - Matching

    @Test("Each voice joins the corpus as one named meeting of its person")
    func corpusEntries() {
        let laura = UUID()
        let user = UUID()
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let imported = [
            ImportedVoice(id: UUID(), personID: laura, name: "Laura", vector: [1, 0], model: "m",
                          samples: 3, speechSeconds: 200, updatedAt: date),
            ImportedVoice(id: UUID(), personID: nil, name: "You", vector: [0, 1], model: "m",
                          samples: 9, speechSeconds: 50, updatedAt: date),
            ImportedVoice(id: UUID(), personID: UUID(), name: "Gone", vector: [1, 1], model: "m",
                          samples: 1, speechSeconds: 60, updatedAt: date),
            ImportedVoice(id: UUID(), personID: laura, name: "Laura", vector: [1, 0, 0], model: "m",
                          samples: 1, speechSeconds: 60, updatedAt: date)
        ]
        let stored = VoiceprintCorpusData(
            kind: .raw, space: "space",
            entries: [VoiceprintData(
                meetingID: UUID(), meetingTitle: "Weekly", meetingDate: date, transcriptID: UUID(),
                speakerID: 1, vector: [0.5, 0.5], speakingDuration: 30, tag: nil
            )],
            people: [:]
        )
        let people = [
            laura: PersonData(id: laura, name: "Laura", email: nil),
            user: PersonData(id: user, name: "Andreas", email: nil)
        ]

        let corpus = ImportedVoiceCorpus.corpus(stored, adding: imported, people: people, user: user)

        #expect(corpus.entries.count == 3)
        #expect(corpus.entries.dropFirst().map(\.tag) == [
            SpeakerTagData(personID: laura, userSet: true),
            SpeakerTagData(personID: user, userSet: true)
        ])
        #expect(corpus.entries.dropFirst().map(\.meetingTitle) == ["TypeWhisper voice profile", "TypeWhisper voice profile"])
        #expect(corpus.entries[2].speakingDuration == 50)
        #expect(Set(corpus.people.keys) == [laura, user])
    }

    @Test("An imported voice names a speaker in the first meeting with medium confidence")
    func matchesFirstMeeting() async throws {
        let store = try DataStore(storage: .inMemory)
        try writeProfiles()
        _ = try await run(store)
        let (meetingID, _) = try await Self.makeMeeting(in: store, vector: [0.95, 0.05, 0, 0])
        let detail = try #require(try await store.meetingDetail(id: meetingID))
        let transcript = try #require(detail.preferredTranscript)

        let result = try await VoiceprintEvidence.compute(
            store: store, meetingID: meetingID, transcript: transcript, detail: detail,
            human: [:], consent: consent, imported: voices
        )

        let match = try #require(result.matches[0])
        #expect(match.level == .medium)
        let laura = try #require(voices.load().first?.personID)
        #expect(match.candidates.map(\.personID) == [laura])
        #expect(result.block.contains("Laura"))
    }
}
