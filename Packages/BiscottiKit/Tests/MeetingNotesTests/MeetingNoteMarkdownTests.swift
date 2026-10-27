import Foundation
import Testing
@testable import MeetingNotes

@Suite("Meeting note Markdown")
struct MeetingNoteMarkdownTests {
    static let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt
    /// 2025-10-09 10:53:20 in Berlin.
    static let start = Date(timeIntervalSince1970: 1_759_999_999 + 1)

    private func input(
        title: String = "Slack Huddle",
        notes: String? = "- Entscheidung",
        callTitle: String? = nil,
        speakers: [String] = []
    ) -> MeetingNoteMarkdown.Input {
        MeetingNoteMarkdown.Input(
            title: title,
            startDate: Self.start,
            endDate: Self.start.addingTimeInterval(1800),
            audioURL: URL(fileURLWithPath: "/Recordings/Slack Huddle 1053/mic.aac"),
            templateName: "Besprechungsnotizen",
            notes: notes,
            failure: notes == nil ? "Kein Modell" : nil,
            transcript: "[00:00] Andreas: Hallo.\n\n[00:04] Laura: Hi.",
            callTitle: callTitle,
            speakers: speakers
        )
    }

    private func frontmatter(of markdown: String) -> String {
        let parts = markdown.components(separatedBy: "\n---\n")
        return (parts.first ?? "") + "\n---"
    }

    @Test("The frontmatter has the fork's fields in its order")
    func frontmatterFields() {
        let markdown = MeetingNoteMarkdown.render(
            input(callTitle: "Weekly", speakers: ["Sprecher 2", "Andreas", "Laura"]),
            timeZone: Self.berlin
        )
        #expect(frontmatter(of: markdown) == """
        ---
        type: "meeting-notes"
        title: "Slack Huddle"
        callTitle: "Weekly"
        date: 2025-10-09
        start: 2025-10-09T10:53:20
        end: 2025-10-09T11:23:20
        timeZone: "Europe/Berlin"
        speakers:
          - "Sprecher 2"
          - "Andreas"
          - "Laura"
        sourceAudio: "/Recordings/Slack Huddle 1053/mic.aac"
        template: "Besprechungsnotizen"
        aiStatus: "ok"
        ---
        """)
    }

    @Test("Heading, audio link, notes and transcript follow the frontmatter")
    func body() {
        let markdown = MeetingNoteMarkdown.render(input(), timeZone: Self.berlin)
        #expect(markdown.hasSuffix("""
        ---

        # Slack Huddle

        Audio: [mic.aac](file:///Recordings/Slack%20Huddle%201053/mic.aac)

        ## Notizen

        - Entscheidung

        ## Transkript

        [00:00] Andreas: Hallo.

        [00:04] Laura: Hi.

        """))
    }

    @Test("Without notes the note says why and marks the AI status failed")
    func failedNotes() {
        let markdown = MeetingNoteMarkdown.render(input(notes: nil), timeZone: Self.berlin)
        #expect(markdown.contains("aiStatus: \"failed\""))
        #expect(markdown.contains("## Notizen\n\n> [!warning] KI-Aufbereitung fehlgeschlagen\n> Kein Modell\n"))
    }

    @Test("Empty call titles and speaker names are left out")
    func emptyFieldsLeftOut() {
        let markdown = MeetingNoteMarkdown.render(input(callTitle: "  ", speakers: ["", " \n"]), timeZone: Self.berlin)
        #expect(!frontmatter(of: markdown).contains("callTitle"))
        #expect(!frontmatter(of: markdown).contains("speakers"))
    }

    @Test("YAML quoting escapes every unsafe character")
    func yamlQuoting() {
        let quoted = MeetingNoteMarkdown.yamlQuoted
        #expect(quoted("A\u{07}\u{2028}") == #""A\u0007\u2028""#)
        #expect(quoted("a\u{80}b\u{85}c") == #""a\u0080b\u0085c""#)
        #expect(quoted("Weekly: \"Sync\"\n- x") == #""Weekly: \"Sync\"\n- x""#)
        #expect(quoted(" ~\u{A0}\u{E9}") == "\" ~\u{A0}\u{E9}\"")
    }
}
