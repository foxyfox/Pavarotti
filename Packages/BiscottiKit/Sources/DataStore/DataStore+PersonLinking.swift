import Foundation
import SwiftData

// MARK: - Pavarotti: one person per human

/// One person taken into another.
public struct PersonMerge: Equatable, Sendable {
    /// The person that no longer exists.
    public let sourceID: UUID
    /// The person that took over the source's meetings, speakers and email.
    public let targetID: UUID

    public init(sourceID: UUID, targetID: UUID) {
        self.sourceID = sourceID
        self.targetID = targetID
    }
}

public extension DataStore {
    /// Takes `sourceID` into `targetID`: the target becomes participant, organizer, the
    /// calendar's user and the named speaker wherever the source was, takes the source's
    /// email when it has none (and its name when its own is only an address), and the
    /// source is deleted. Does nothing when both are the same.
    func mergePerson(_ sourceID: UUID, into targetID: UUID) throws {
        guard sourceID != targetID else { return }
        guard let source = try fetchPerson(id: sourceID) else { throw DataStoreError.notFound(sourceID) }
        guard let target = try fetchPerson(id: targetID) else { throw DataStoreError.notFound(targetID) }

        for meeting in Array(source.meetings) {
            var participants = meeting.participants.filter { $0.id != sourceID }
            if !participants.contains(where: { $0.id == targetID }) {
                participants.append(target)
            }
            meeting.participants = participants
        }
        for meeting in Array(source.organizedMeetings) {
            meeting.organizer = target
        }
        try moveUserMarkAndSpeakers(from: sourceID, to: targetID)
        if (target.email ?? "").isEmpty, let email = source.email, !email.isEmpty {
            target.email = email
        }
        if !PersonNames.isRealName(target.name), PersonNames.isRealName(source.name) {
            target.name = source.name
        }
        context.delete(source)
        try save()
    }

    /// Joins people the calendar created with the people the user named, where their
    /// full names agree (also the name in a calendar address), and gives calendar people
    /// without a name the one in their address. The named person stays and takes the
    /// email. Returns the merges, so voices and consents kept outside the store follow.
    @discardableResult
    func linkCalendarPeopleToNamedPeople() throws -> [PersonMerge] {
        let people = try context.fetch(FetchDescriptor<Person>())
        for person in people where !PersonNames.isRealName(person.name) {
            let name = PersonNames.displayName(name: person.name, email: person.email)
            if PersonNames.isRealName(name) {
                person.name = name
            }
        }
        var merges: [PersonMerge] = []
        for calendarPerson in people where !(calendarPerson.email ?? "").isEmpty {
            let keys = PersonNames.matchKeys(name: calendarPerson.name, email: calendarPerson.email)
            guard !keys.isEmpty else { continue }
            let named = people.filter { person in
                (person.email ?? "").isEmpty && !PersonNames.matchKeys(person.name).isDisjoint(with: keys)
            }
            guard named.count == 1 else { continue }
            merges.append(PersonMerge(sourceID: calendarPerson.id, targetID: named[0].id))
        }
        try save()
        for merge in merges {
            try mergePerson(merge.sourceID, into: merge.targetID)
        }
        return merges
    }
}

extension DataStore {
    /// Points the calendar's user mark and every named speaker of `sourceID` at `targetID`.
    private func moveUserMarkAndSpeakers(from sourceID: UUID, to targetID: UUID) throws {
        for snapshot in try context.fetch(FetchDescriptor<CalendarSnapshot>())
            where snapshot.currentUserPersonID == sourceID
        {
            snapshot.currentUserPersonID = targetID
        }
        for record in try context.fetch(FetchDescriptor<TranscriptRecord>()) {
            let assignments = record.speakerAssignments
            guard assignments.values.contains(where: { $0.personID == sourceID }) else { continue }
            record.speakerAssignments = assignments.mapValues { entry in
                entry.personID == sourceID ? SpeakerAssignmentEntry(personID: targetID, userSet: entry.userSet) : entry
            }
        }
    }

    /// The one person a calendar participant with an unknown email most likely is: the
    /// only person without an email whose full name agrees, else the only person at all.
    /// A person without an email takes this one. `nil` when nobody or several fit.
    func personLinked(name: String, email: String) throws -> UUID? {
        let keys = PersonNames.matchKeys(name: name, email: email)
        guard !keys.isEmpty else { return nil }
        let candidates = try context.fetch(FetchDescriptor<Person>()).filter {
            !PersonNames.matchKeys(name: $0.name, email: $0.email).isDisjoint(with: keys)
        }
        let withoutEmail = candidates.filter { ($0.email ?? "").isEmpty }
        if withoutEmail.count == 1 {
            withoutEmail[0].email = email
            try save()
            return withoutEmail[0].id
        }
        return withoutEmail.isEmpty && candidates.count == 1 ? candidates[0].id : nil
    }

    /// The only person whose full name agrees with `name` in another spelling, such as
    /// "max müller" for "Max Mueller". `nil` when nobody or several fit.
    func personMatchingFullName(_ name: String) throws -> UUID? {
        let keys = PersonNames.matchKeys(name)
        guard !keys.isEmpty else { return nil }
        let candidates = try context.fetch(FetchDescriptor<Person>()).filter {
            !PersonNames.matchKeys(name: $0.name, email: $0.email).isDisjoint(with: keys)
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }
}
