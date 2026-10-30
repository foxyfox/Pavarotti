import DataStore
import Foundation
import Testing
@testable import MeetingNotes

func segment(_ speakerID: Int?, _ start: TimeInterval, _ text: String, label: String = "") -> SegmentData {
    SegmentData(id: UUID(), speakerID: speakerID, speakerLabel: label, startTime: start, endTime: start + 1, text: text)
}

func transcript(_ segments: [SegmentData], names: [Int: String] = [:]) -> TranscriptData {
    TranscriptData(
        id: UUID(),
        createdAt: Date(),
        speakerCount: 2,
        segments: segments,
        speakerAssignments: names.mapValues { PersonData(id: UUID(), name: $0) }
    )
}

@Suite("Meeting note transcript")
struct MeetingNoteTranscriptTests {
    @Test("Consecutive segments of a speaker become one paragraph")
    func mergesSpeakers() {
        let spoken = MeetingNoteTranscript(transcript([
            segment(0, 0, "Hallo."),
            segment(0, 2.5, " Wie geht's? "),
            segment(1, 4.9, "Gut."),
            segment(1, 6, "  "),
            segment(0, 75 * 60 + 12.7, "Tschüss.")
        ], names: [0: "Andreas"]))

        #expect(spoken.text == """
        [00:00] Andreas: Hallo. Wie geht's?

        [00:04] Sprecher 2: Gut.

        [75:12] Andreas: Tschüss.
        """)
        #expect(spoken.speakers == ["Andreas", "Sprecher 2"])
        #expect(spoken.wordCount == 5)
    }

    @Test("Speakers named as the same person speak in one paragraph")
    func mergesSamePerson() {
        let franziska = PersonData(id: UUID(), name: "Franziska")
        let spoken = MeetingNoteTranscript(TranscriptData(
            id: UUID(),
            createdAt: Date(),
            speakerCount: 3,
            segments: [segment(0, 0, "Hallo."), segment(1, 1, "Wir fahren."), segment(2, 2, "Nach München."), segment(3, 3, "Gut.")],
            speakerAssignments: [0: franziska, 1: franziska, 2: franziska]
        ))
        #expect(spoken.text == """
        [00:00] Franziska: Hallo. Wir fahren. Nach München.

        [00:03] Sprecher 4: Gut.
        """)
    }

    @Test("Segments without a speaker use their label or \"Unbekannt\"")
    func unassignedSegments() {
        let spoken = MeetingNoteTranscript(transcript([
            segment(nil, 0, "Eins.", label: " "),
            segment(nil, 1, "Zwei.", label: "Gast"),
            segment(nil, 2, "Drei.", label: "Gast")
        ]))
        #expect(spoken.utterances.map(\.speaker) == ["Unbekannt", "Gast", "Gast"])
    }

    @Test("A blank person name falls back to the speaker number")
    func blankName() {
        let spoken = MeetingNoteTranscript(transcript([segment(2, 0, "Hi.")], names: [2: "  "]))
        #expect(spoken.speakers == ["Sprecher 3"])
    }
}

@Suite("Meeting note file names")
struct MeetingNoteFileNameTests {
    let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt
    /// 2025-10-09 10:53:20 in Berlin.
    let start = Date(timeIntervalSince1970: 1_760_000_000)

    @Test("Date, time and the title, safe for SMB, OneDrive and Obsidian")
    func baseName() {
        #expect(MeetingNoteFileName.baseName(title: "Weekly: Sync / Plan", start: start, timeZone: berlin)
            == "20251009 1053 - Weekly \u{2013} Sync \u{2013} Plan - Notizen")
        #expect(MeetingNoteFileName.baseName(title: "\"Q4\" [Review] #1?", start: start, timeZone: berlin)
            == "20251009 1053 - Q4 Review 1 - Notizen")
    }

    @Test("Without a usable title the name is date, time and \"Notizen\"")
    func emptyTitle() {
        #expect(MeetingNoteFileName.baseName(title: " ?*. ", start: start, timeZone: berlin) == "20251009 1053 - Notizen")
    }

    @Test("Long titles are cut between characters")
    func longTitle() {
        let name = MeetingNoteFileName.baseName(title: String(repeating: "ä", count: 200), start: start, timeZone: berlin)
        #expect(name == "20251009 1053 - " + String(repeating: "ä", count: 67) + " - Notizen")
    }

    @Test("A taken name gets a number")
    func availableURL() {
        let taken: Set = ["/Notes/A.md", "/Notes/A 2.md"]
        let url = MeetingNoteFileName.availableURL(in: URL(fileURLWithPath: "/Notes", isDirectory: true), baseName: "A") {
            taken.contains($0)
        }
        #expect(url.path == "/Notes/A 3.md")
    }
}
