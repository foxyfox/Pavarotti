import DataStore
import Foundation
import Intelligence
import os

/// Pavarotti: one person per human, whether the calendar or the user named them.
public extension AppCore {
    /// Takes `sourceID` into `targetID` (see `DataStore.mergePerson`); the source's voice
    /// consent and imported voices go to the target.
    func mergePerson(_ sourceID: UUID, into targetID: UUID) async throws {
        try await store.mergePerson(sourceID, into: targetID)
        try personsMerged([PersonMerge(sourceID: sourceID, targetID: targetID)])
    }

    /// Joins the people the calendar created with the people the user named under the
    /// same full name. Runs at every launch; does nothing once they are joined.
    func linkCalendarPeopleToNamedPeople() async {
        let logger = Logger(subsystem: "de.foxagon.pavarotti", category: "People")
        do {
            let merges = try await store.linkCalendarPeopleToNamedPeople()
            try personsMerged(merges)
            if !merges.isEmpty {
                logger.info("Joined \(merges.count, privacy: .public) calendar people with named people")
            }
        } catch {
            logger.error("People could not be joined: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func personsMerged(_ merges: [PersonMerge]) throws {
        for merge in merges {
            intelligence.voiceConsent?.follow(merge)
            try intelligence.importedVoices?.follow(merge)
        }
    }
}
