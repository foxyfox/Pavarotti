import DataStore
import Foundation
import VoiceprintMatching

/// Pavarotti: a voice taken over from TypeWhisper. In voice matching it counts like one
/// meeting in which the user named the speaker, so on its own it names someone with at
/// most medium confidence; meetings named in Pavarotti add to it.
public struct ImportedVoice: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// The person the voice belongs to; `nil` for the user's own voice, which goes to
    /// whoever the calendar marks as the user, else to the named speaker it sounds like.
    public let personID: UUID?
    public let name: String
    public let vector: [Float]
    /// The speaker model that made `vector`, as TypeWhisper names it.
    public let model: String
    /// Meetings (for the own voice: dictations) the voice was averaged from.
    public let samples: Int
    public let speechSeconds: Double
    public let updatedAt: Date

    public init(
        id: UUID, personID: UUID?, name: String, vector: [Float], model: String,
        samples: Int, speechSeconds: Double, updatedAt: Date
    ) {
        self.id = id
        self.personID = personID
        self.name = name
        self.vector = vector
        self.model = model
        self.samples = samples
        self.speechSeconds = speechSeconds
        self.updatedAt = updatedAt
    }
}

/// Pavarotti: keeps the imported voices in `imported-voices.json`, readable only by the
/// user: voice embeddings are biometric data.
public struct ImportedVoiceStore: Sendable {
    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Pavarotti/imported-voices.json", directoryHint: .notDirectory)
    }

    public let fileURL: URL

    public init(fileURL: URL = ImportedVoiceStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// The imported voices; empty without a file or when it cannot be read.
    public func load() -> [ImportedVoice] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ImportedVoice].self, from: data)) ?? []
    }

    /// Replaces the imported voices.
    public func save(_ voices: [ImportedVoice]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(voices).write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Forgets every imported voice. Names and consents stay.
    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// Pavarotti: adds the imported voices to the voiceprint corpus.
enum ImportedVoiceCorpus {
    /// The meeting title the voice debug window shows for an imported voice.
    static let meetingTitle = "TypeWhisper voice profile"

    /// How similar (cosine) the own voice must be to a speaker the user named to go to
    /// that person when the calendar marks nobody as the user: the matcher's accept radius.
    static let ownVoiceSimilarity = 1 - Double(VoiceprintConfig().thresholds.acceptRadius)

    /// The corpus with the voices from `store` added, their people looked up, and the
    /// person who got the user's own voice.
    static func corpus(
        _ corpus: VoiceprintCorpusData, adding imported: ImportedVoiceStore, store: DataStore
    ) async throws -> (corpus: VoiceprintCorpusData, user: UUID?) {
        let voices = imported.load()
        guard !voices.isEmpty else { return (corpus, nil) }
        var user: UUID?
        if let own = voices.first(where: { $0.personID == nil }) {
            let named = corpus.entries.compactMap { entry -> (personID: UUID, vector: [Float])? in
                guard let tag = entry.tag, tag.userSet else { return nil }
                return (tag.personID, entry.vector)
            }
            user = try await store.mostFrequentCurrentUserPersonID()
                ?? ownVoicePerson(own, voices: voices, named: named)
        }
        let ids = Set(voices.compactMap(\.personID)).union(user.map { [$0] } ?? [])
        let people = try await store.people(ids: ids)
        return (Self.corpus(corpus, adding: voices, people: people, user: user), user)
    }

    /// The person whose speakers, as the user named them, sound most like the own voice
    /// `own`: at least `ownVoiceSimilarity` alike. People with an imported voice of their
    /// own are left out. `nil` when nobody is that close.
    static func ownVoicePerson(
        _ own: ImportedVoice, voices: [ImportedVoice], named: [(personID: UUID, vector: [Float])]
    ) -> UUID? {
        let others = Set(voices.compactMap(\.personID))
        var best: (personID: UUID, similarity: Double)?
        for (personID, vector) in named where !others.contains(personID) {
            guard let similarity = TypeWhisperVoiceImport.cosine(own.vector, vector),
                  similarity >= ownVoiceSimilarity, similarity > best?.similarity ?? -1
            else { continue }
            best = (personID, similarity)
        }
        return best?.personID
    }

    /// The corpus with one confirmed entry per voice whose person exists and whose
    /// vector has the corpus's length. The own voice goes to `user`.
    static func corpus(
        _ corpus: VoiceprintCorpusData, adding voices: [ImportedVoice],
        people: [UUID: PersonData], user: UUID?
    ) -> VoiceprintCorpusData {
        let dimension = corpus.entries.first?.vector.count
        var entries = corpus.entries
        var known = corpus.people
        for voice in voices {
            guard let personID = voice.personID ?? user, let person = people[personID],
                  dimension == nil || voice.vector.count == dimension
            else { continue }
            entries.append(VoiceprintData(
                meetingID: voice.id, meetingTitle: meetingTitle, meetingDate: voice.updatedAt,
                transcriptID: voice.id, speakerID: 0, vector: voice.vector,
                speakingDuration: voice.speechSeconds,
                tag: SpeakerTagData(personID: personID, userSet: true)
            ))
            known[personID] = person
        }
        return VoiceprintCorpusData(kind: corpus.kind, space: corpus.space, entries: entries, people: known)
    }
}
