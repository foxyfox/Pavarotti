import DataStore
import Foundation
import Testing
@testable import Intelligence

/// Pavarotti: consents and imported voices go along when two people are merged.
@Suite("Person merge: voices and consents")
struct PersonMergeVoicesTests {
    @Test("The source's consent goes to the target unless the target has its own")
    func consentFollows() throws {
        let defaults = try #require(UserDefaults(suiteName: "PersonMergeVoicesTests.\(UUID().uuidString)"))
        let consent = VoiceConsentStore(defaults: defaults)
        let source = UUID(), target = UUID(), other = UUID()
        let noted = Date(timeIntervalSince1970: 1_760_000_000)
        let own = Date(timeIntervalSince1970: 1_770_000_000)
        consent.setConsent(true, for: source, at: noted)

        consent.follow(PersonMerge(sourceID: source, targetID: target))
        #expect(consent.consentDate(for: target) == noted)
        #expect(consent.consentDate(for: source) == nil)

        consent.setConsent(true, for: other, at: noted)
        consent.setConsent(true, for: target, at: own)
        consent.follow(PersonMerge(sourceID: other, targetID: target))
        #expect(consent.consentDate(for: target) == own)
        #expect(consent.consentedPersonIDs() == [target])
    }

    @Test("Imported voices of the source belong to the target afterwards")
    func importedVoicesFollow() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "merge-voices-\(UUID().uuidString)")
        let store = ImportedVoiceStore(fileURL: folder.appending(path: "imported-voices.json"))
        let source = UUID(), target = UUID()
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let voice = ImportedVoice(
            id: UUID(), personID: source, name: "Max", vector: [1, 0], model: "m",
            samples: 2, speechSeconds: 30, updatedAt: date
        )
        let own = ImportedVoice(
            id: UUID(), personID: nil, name: "You", vector: [0, 1], model: "m",
            samples: 3, speechSeconds: 40, updatedAt: date
        )
        try store.save([voice, own])

        try store.follow(PersonMerge(sourceID: source, targetID: target))

        let loaded = store.load()
        #expect(loaded.map(\.personID) == [target, nil])
        #expect(loaded.first?.vector == [1, 0])
    }
}
