import DataStore
import Foundation

/// Pavarotti: takes over the voices of Andreas's TypeWhisper fork from its
/// `speaker-profiles.json`: everyone who consented, with name, consent date and voice,
/// and the user's own voice. Nothing is written back to TypeWhisper.
///
/// Both apps embed voices with WeSpeaker ResNet34 as pyannote community-1 uses it, so the
/// voices should fit Pavarotti's voiceprints. The import compares them with the speakers
/// already named in Pavarotti, so the user sees whether they do.
public enum TypeWhisperVoiceImport {
    public static var profilesURL: URL {
        URL.applicationSupportDirectory.appending(path: "TypeWhisper/speaker-profiles.json", directoryHint: .notDirectory)
    }

    /// TypeWhisper uses the own voice from this much dictation speech on.
    static let minimumOwnSpeechSeconds: Double = 10

    /// How close an imported voice is to the speakers named as that person in Pavarotti.
    public struct Comparison: Equatable, Sendable {
        public let name: String
        /// Cosine similarity to the closest of them.
        public let similarity: Double
    }

    /// What one import took over, for the Settings caption.
    public struct Outcome: Equatable, Sendable {
        public var foundFile = true
        public var people: [String] = []
        public var ownVoice = false
        /// Whether the calendar marks someone as the user, who gets the own voice.
        public var userKnown = false
        public var comparisons: [Comparison] = []

        public var summary: String {
            guard foundFile else { return "TypeWhisper has no saved voices." }
            guard !people.isEmpty || ownVoice else { return "TypeWhisper\u{2019}s voice file holds no usable voice." }
            var parts = [tookOver]
            if ownVoice, !userKnown {
                parts.append("Your own voice counts once the calendar shows which attendee you are.")
            }
            if comparisons.isEmpty {
                parts.append("Name a speaker in a meeting and import again to see whether the voices fit Pavarotti\u{2019}s.")
            } else {
                let values = comparisons.map { "\($0.name) \(String(format: "%.2f", $0.similarity))" }
                parts.append(
                    "Similarity to the speakers you named here: \(values.joined(separator: ", ")). "
                        + "The same voice usually reaches 0.6 or more."
                )
            }
            return parts.joined(separator: " ")
        }

        private var tookOver: String {
            let names = people.count > 3 ? people.prefix(3).joined(separator: ", ") + ", \u{2026}" : people.joined(separator: ", ")
            switch (people.isEmpty, ownVoice) {
            case (true, _): return "Took over your own voice."
            case (false, true): return "Took over \(people.count) voices (\(names)) and your own."
            case (false, false): return "Took over \(people.count) voices (\(names))."
            }
        }
    }

    /// Takes over the voices in `fileURL`, replacing the ones imported before. Each person
    /// is matched to an existing one by name or created; their consent comes along unless
    /// Pavarotti already has a note.
    public static func run(
        fileURL: URL = TypeWhisperVoiceImport.profilesURL,
        store: DataStore,
        consent: VoiceConsentStore?,
        voices: ImportedVoiceStore
    ) async throws -> Outcome {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Outcome(foundFile: false)
        }
        let profiles = try TypeWhisperVoiceProfiles.read(from: fileURL)
        var outcome = Outcome()
        var imported: [ImportedVoice] = []
        for person in profiles.people ?? [] {
            let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, isUsable(person.embedding) else { continue }
            let personID = try await resolvedPerson(named: name, store: store)
            if let consent, consent.consentDate(for: personID) == nil {
                consent.setConsent(true, for: personID, at: person.consentDate)
            }
            imported.append(ImportedVoice(
                id: UUID(uuidString: person.id) ?? UUID(), personID: personID, name: name,
                vector: person.embedding, model: person.embeddingModel, samples: person.count,
                speechSeconds: person.speechSeconds, updatedAt: person.updatedAt
            ))
            outcome.people.append(name)
        }
        if let own = profiles.own, own.speechSeconds >= minimumOwnSpeechSeconds, isUsable(own.embedding) {
            imported.append(ImportedVoice(
                id: UUID(), personID: nil, name: "You", vector: own.embedding, model: own.embeddingModel,
                samples: own.dictationCount + own.meetingCount, speechSeconds: own.speechSeconds,
                updatedAt: own.updatedAt
            ))
            outcome.ownVoice = true
        }
        try voices.save(imported)
        let user = try await store.mostFrequentCurrentUserPersonID()
        outcome.userKnown = user != nil
        outcome.comparisons = try await compare(imported, user: user, store: store)
        return outcome
    }

    // MARK: - Private

    private static func resolvedPerson(named name: String, store: DataStore) async throws -> UUID {
        if let personID = try await store.personID(matchingName: name) {
            return personID
        }
        return try await store.findOrCreatePerson(name: name, email: nil)
    }

    private static func compare(_ voices: [ImportedVoice], user: UUID?, store: DataStore) async throws -> [Comparison] {
        let named = try await store.confirmedVoiceprints(kind: .raw)
        return voices.compactMap { voice in
            guard let personID = voice.personID ?? user,
                  let best = named[personID]?.compactMap({ cosine(voice.vector, $0) }).max()
            else { return nil }
            return Comparison(name: voice.personID == nil ? "you" : voice.name, similarity: best)
        }
    }

    static func isUsable(_ vector: [Float]) -> Bool {
        !vector.isEmpty && vector.allSatisfy(\.isFinite) && vector.contains { $0 != 0 }
    }

    /// Cosine similarity; `nil` when the lengths differ or a vector is zero.
    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot = 0.0, lhsNorm = 0.0, rhsNorm = 0.0
        for (left, right) in zip(lhs, rhs) {
            dot += Double(left) * Double(right)
            lhsNorm += Double(left) * Double(left)
            rhsNorm += Double(right) * Double(right)
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return nil }
        return dot / (lhsNorm.squareRoot() * rhsNorm.squareRoot())
    }
}

// MARK: - TypeWhisper's file

/// The parts of TypeWhisper's `speaker-profiles.json` (schema 1 or 2) the import uses.
struct TypeWhisperVoiceProfiles: Decodable {
    struct OwnVoice: Decodable {
        let embedding: [Float]
        let embeddingModel: String
        let dictationCount: Int
        let meetingCount: Int
        let speechSeconds: Double
        let updatedAt: Date
    }

    struct PersonVoice: Decodable {
        let id: String
        let name: String
        let embedding: [Float]
        let embeddingModel: String
        let count: Int
        let speechSeconds: Double
        let consentDate: Date
        let updatedAt: Date
    }

    let own: OwnVoice?
    let people: [PersonVoice]?

    /// Reads the file; dates are ISO 8601, with or without fractional seconds.
    static func read(from url: URL) throws -> TypeWhisperVoiceProfiles {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let precise = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            if let date = (try? precise.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return try decoder.decode(TypeWhisperVoiceProfiles.self, from: Data(contentsOf: url))
    }
}
