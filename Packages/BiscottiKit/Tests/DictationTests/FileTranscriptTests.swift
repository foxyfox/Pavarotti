import Foundation
import Testing
@testable import Dictation

@Suite("File transcript")
struct FileTranscriptTests {
    private func transcript(_ passages: [TimedText], language: String? = "de") -> FileTranscript {
        FileTranscript(
            source: URL(fileURLWithPath: "/Users/andreas/Interview [Q3].m4a"),
            duration: 4512.7,
            language: language,
            passages: passages,
            createdAt: Date(timeIntervalSince1970: 1_793_116_800)
        )
    }

    @Test("Passages join into paragraphs until a pause")
    func paragraphsSplitAtPauses() {
        let result = transcript([
            TimedText(start: 0, end: 3, text: " Hallo "),
            TimedText(start: 3.5, end: 6, text: "zusammen."),
            TimedText(start: 6.5, end: 7, text: "  "),
            TimedText(start: 9, end: 12, text: "Neuer Absatz.")
        ])
        #expect(result.paragraphs == [
            TimedText(start: 0, end: 6, text: "Hallo zusammen."),
            TimedText(start: 9, end: 12, text: "Neuer Absatz.")
        ])
    }

    @Test("A paragraph ends after a minute even without a pause")
    func paragraphsSplitAfterAMinute() {
        let passages = (0 ..< 13).map { TimedText(start: Double($0) * 10, end: Double($0) * 10 + 9.5, text: "Satz \($0).") }
        let starts = transcript(passages).paragraphs.map(\.start)
        #expect(starts == [0, 60, 120])
    }

    @Test("Timestamps are minutes and seconds like in the meeting notes")
    func timestamps() {
        #expect(FileTranscript.timestamp(0) == "00:00")
        #expect(FileTranscript.timestamp(59.9) == "00:59")
        #expect(FileTranscript.timestamp(4512.7) == "75:12")
        #expect(FileTranscript.timestamp(-3) == "00:00")
        #expect(FileTranscript.timestamp(.nan) == "00:00")
    }

    @Test("The Markdown note has frontmatter, a heading, the audio link and the transcript")
    func markdown() throws {
        let result = transcript([
            TimedText(start: 0, end: 2, text: "Hallo zusammen."),
            TimedText(start: 4500, end: 4510, text: "Tschüss.")
        ])
        let utc = try #require(TimeZone(identifier: "UTC"))
        let link = result.source.absoluteString
        #expect(result.markdown(timeZone: utc) == """
        ---
        type: "transcript"
        title: "Interview [Q3]"
        date: 2026-10-27
        sourceAudio: "/Users/andreas/Interview [Q3].m4a"
        duration: "75:12"
        language: "de"
        ---

        # Interview [Q3]

        Audio: [Interview \\[Q3\\].m4a](\(link))

        ## Transkript

        [00:00] Hallo zusammen.

        [75:00] Tschüss.

        """)
        #expect(result.markdownFileName == "Interview [Q3].md")
    }

    @Test("An unknown language is left out of the frontmatter")
    func noLanguage() {
        let markdown = transcript([TimedText(start: 0, end: 1, text: "Hi")], language: nil).markdown()
        #expect(!markdown.contains("language:"))
    }

    @Test("YAML values escape quotes, backslashes and control characters")
    func yamlQuoting() {
        #expect(FileTranscript.yamlQuoted("a\"b\\c\nd\u{0007}e\u{2028}") == #""a\"b\\c\nd\u0007e\u2028""#)
    }
}
