import DataStore
import Foundation
import Testing
@testable import MeetingNotes

@Suite("Meeting notes writer")
struct MeetingNotesWriterTests {
    let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt
    /// 2025-10-09 10:53:20 in Berlin.
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    let meetingID = UUID()
    let audio = URL(fileURLWithPath: "/Recordings/Standup/mic.aac")

    /// A settings store on its own defaults suite and a notes folder in a temp directory.
    private struct Fixture {
        let store: MeetingNotesSettingsStore
        let folder: URL
        let defaults: UserDefaults
        let suite: String

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func makeFixture() throws -> Fixture {
        let suite = "MeetingNotesWriterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        let store = MeetingNotesSettingsStore(defaults: defaults)
        var settings = MeetingNotesSettings()
        settings.folderPath = folder.path
        settings.templateName = "Besprechungsnotizen"
        store.save(settings)
        return Fixture(store: store, folder: folder, defaults: defaults, suite: suite)
    }

    private func detail(title: String = "Standup", words: Int = 24, summary: String = "- Punkt") -> MeetingDetailData {
        let text = Array(repeating: "Wort", count: words).joined(separator: " ")
        return MeetingDetailData(
            id: meetingID,
            title: title,
            date: start,
            duration: nil,
            recordingDuration: 900,
            hasAudio: true,
            preferredTranscript: transcript([segment(0, 0, text)], names: [0: "Andreas"]),
            summary: summary
        )
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test("The note file is found while it is still there")
    func existingNote() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        #expect(store.existingNoteURL(for: meetingID) == nil)

        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        let note = fixture.folder.appending(path: "Standup - Notizen.md")
        try Data("# Standup".utf8).write(to: note)
        store.setNoteURL(note, for: meetingID)
        #expect(store.existingNoteURL(for: meetingID)?.path == note.path)

        try FileManager.default.removeItem(at: note)
        #expect(store.existingNoteURL(for: meetingID) == nil)
    }

    @Test("A note is written into the folder under the fork's file name")
    func writesNote() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, folder = fixture.folder

        let outcome = try MeetingNotesWriter(store: store, timeZone: berlin).write(detail(), audioURL: audio, failure: nil)

        let url = folder.appending(path: "20251009 1053 - Standup - Notizen.md", directoryHint: .notDirectory)
        #expect(outcome == .written(url))
        let markdown = try String(contentsOf: url, encoding: .utf8)
        #expect(markdown.contains("end: 2025-10-09T11:08:20\n"))
        #expect(markdown.contains("template: \"Besprechungsnotizen\"\n"))
        #expect(markdown.contains("## Notizen\n\n- Punkt\n"))
        #expect(markdown.contains("[00:00] Andreas: Wort Wort"))
        #expect(store.noteURL(for: meetingID)?.path == url.path)
    }

    @Test("A later run rewrites the note and renames it when the title changed")
    func rewritesNote() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, folder = fixture.folder
        let writer = MeetingNotesWriter(store: store, timeZone: berlin)

        _ = try writer.write(detail(summary: ""), audioURL: audio, failure: "Kein Modell")
        _ = try writer.write(detail(), audioURL: audio, failure: nil)
        #expect(try names(in: folder) == ["20251009 1053 - Standup - Notizen.md"])

        _ = try writer.write(detail(title: "Planung"), audioURL: audio, failure: nil)
        #expect(try names(in: folder) == ["20251009 1053 - Planung - Notizen.md"])
        let markdown = try String(contentsOf: #require(store.noteURL(for: meetingID)), encoding: .utf8)
        #expect(markdown.contains("# Planung\n"))
        #expect(markdown.contains("aiStatus: \"ok\""))
    }

    @Test("Another meeting with the same title and start gets its own file")
    func sameNameOtherMeeting() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, folder = fixture.folder
        let writer = MeetingNotesWriter(store: store, timeZone: berlin)

        _ = try writer.write(detail(), audioURL: audio, failure: nil)
        let other = MeetingDetailData(
            id: UUID(), title: "Standup", date: start, duration: nil, hasAudio: true,
            preferredTranscript: detail().preferredTranscript
        )
        _ = try writer.write(other, audioURL: audio, failure: nil)
        _ = try writer.write(other, audioURL: audio, failure: nil)

        #expect(try names(in: folder) == ["20251009 1053 - Standup - Notizen 2.md", "20251009 1053 - Standup - Notizen.md"])
    }

    @Test("Short transcripts, missing audio and switched-off notes write nothing")
    func skips() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, folder = fixture.folder
        let writer = MeetingNotesWriter(store: store, timeZone: berlin)

        #expect(try writer.write(detail(words: 19), audioURL: audio, failure: nil) == .skipped(reason: "Transcript too short (19 words)."))
        #expect(try writer.write(detail(), audioURL: nil, failure: nil) == .skipped(reason: "No recording."))
        var settings = store.load()
        settings.isEnabled = false
        store.save(settings)
        #expect(try writer.write(detail(), audioURL: audio, failure: nil) == .skipped(reason: "Meeting notes are off."))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("Without a summary the note carries the reason")
    func failureReason() {
        let spoken = MeetingNoteTranscript(transcript([segment(0, 0, "Hallo")]))
        let input = MeetingNotesWriter.input(
            for: detail(title: " ", summary: "  "), transcript: spoken, audioURL: audio, failure: nil, settings: MeetingNotesSettings()
        )
        #expect(input.notes == nil)
        #expect(input.failure == "Es gibt noch keine KI-Zusammenfassung.")
        #expect(input.title.hasPrefix("Aufnahme "))
        #expect(input.templateName == MeetingNotesSettings.defaultTemplateName)
    }

    @Test("An answer wrapped in a code fence is unwrapped")
    func codeFence() {
        #expect(MeetingNotesWriter.strippingOuterCodeFence("```markdown\n# Notizen\n- A\n```") == "# Notizen\n- A")
        #expect(MeetingNotesWriter.strippingOuterCodeFence("- A\n```swift\nx\n```") == "- A\n```swift\nx\n```")
    }
}
