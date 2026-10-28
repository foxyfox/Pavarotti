import Foundation
import SwiftData

// MARK: - Pavarotti: voices taken over from TypeWhisper

public extension DataStore {
    /// The person a bare name from TypeWhisper most likely means: one with exactly this
    /// name (ignoring case and accents), else the only one whose first name it is. `nil`
    /// when nobody fits or several people share the first name.
    func personID(matchingName name: String) throws -> UUID? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let people = try context.fetch(FetchDescriptor<Person>())
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let exact = people.filter { $0.name.compare(wanted, options: options) == .orderedSame }
        // Several people with the same name are the same person from different calendars;
        // the one with an email is the calendar's.
        if let match = exact.min(by: { Self.preferred($0, over: $1) }) {
            return match.id
        }
        guard !wanted.contains(" ") else { return nil }
        let byFirstName = people.filter { person in
            person.name.split(separator: " ").first.map {
                String($0).compare(wanted, options: options) == .orderedSame
            } ?? false
        }
        return byFirstName.count == 1 ? byFirstName[0].id : nil
    }

    /// The person the calendar marks as the user in the most meetings, or `nil`.
    func mostFrequentCurrentUserPersonID() throws -> UUID? {
        let snapshots = try context.fetch(FetchDescriptor<CalendarSnapshot>())
        var counts: [UUID: Int] = [:]
        for case let personID? in snapshots.map(\.currentUserPersonID) {
            counts[personID, default: 0] += 1
        }
        return counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.uuidString > rhs.key.uuidString
        }?.key
    }

    /// The people with these IDs that still exist.
    func people(ids: Set<UUID>) throws -> [UUID: PersonData] {
        let people = try context.fetch(FetchDescriptor<Person>()).filter { ids.contains($0.id) }
        return Dictionary(uniqueKeysWithValues: people.map {
            ($0.id, PersonData(id: $0.id, name: $0.name, email: $0.email))
        })
    }

    /// The voiceprints of preferred transcripts whose speaker a human named, by person,
    /// whatever their embedding space.
    func confirmedVoiceprints(kind: VoiceprintKind) throws -> [UUID: [[Float]]] {
        var vectors: [UUID: [[Float]]] = [:]
        for meeting in try context.fetch(FetchDescriptor<Meeting>()) {
            guard let preferredID = meeting.preferredTranscriptID,
                  let record = meeting.transcripts.first(where: { $0.id == preferredID })
            else { continue }
            let assignments = record.speakerAssignments
            for entry in record.voiceprints where entry.kindRaw == kind.rawValue {
                guard let assignment = assignments[entry.speakerID], assignment.userSet,
                      let vector = VectorCoding.decode(entry.vectorData, dimension: entry.dimension)
                else { continue }
                vectors[assignment.personID, default: []].append(vector)
            }
        }
        return vectors
    }

    private static func preferred(_ lhs: Person, over rhs: Person) -> Bool {
        let lhsHasEmail = !(lhs.email ?? "").isEmpty
        let rhsHasEmail = !(rhs.email ?? "").isEmpty
        if lhsHasEmail != rhsHasEmail { return lhsHasEmail }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
