import Foundation

/// Pavarotti: the Markdown note of a meeting, in the format of Andreas's TypeWhisper fork:
/// YAML frontmatter, a heading, a link to the audio, the AI notes under "Notizen" and the
/// whole transcript under "Transkript". Ported from the fork's renderer.
public enum MeetingNoteMarkdown {
    public struct Input: Equatable, Sendable {
        public var title: String
        public var startDate: Date
        public var endDate: Date
        public var audioURL: URL
        /// The name of the prompt that wrote the notes.
        public var templateName: String
        /// The AI notes in Markdown; `nil` when they could not be written.
        public var notes: String?
        /// Why there are no notes.
        public var failure: String?
        /// "[mm:ss] Name: Text" paragraphs, see ``MeetingNoteTranscript``.
        public var transcript: String
        /// The calendar's or the app's title of the call; left out when nil or empty.
        public var callTitle: String?
        /// The calendar event's title when `callTitle` is the app's; left out when nil or empty.
        public var calendarTitle: String?
        /// Speaker names in order of their first line in the transcript; left out when empty.
        public var speakers: [String]

        public init(
            title: String,
            startDate: Date,
            endDate: Date,
            audioURL: URL,
            templateName: String,
            notes: String?,
            failure: String?,
            transcript: String,
            callTitle: String? = nil,
            calendarTitle: String? = nil,
            speakers: [String] = []
        ) {
            self.title = title
            self.startDate = startDate
            self.endDate = endDate
            self.audioURL = audioURL
            self.templateName = templateName
            self.notes = notes
            self.failure = failure
            self.transcript = transcript
            self.callTitle = callTitle
            self.calendarTitle = calendarTitle
            self.speakers = speakers
        }
    }

    public static func render(_ input: Input, timeZone: TimeZone = .current) -> String {
        let dateFormatter = makeDateFormatter(timeZone: timeZone, format: "yyyy-MM-dd")
        let dateTimeFormatter = makeDateFormatter(timeZone: timeZone, format: "yyyy-MM-dd'T'HH:mm:ss")

        var frontmatter = [
            "---",
            "type: \(yamlQuoted("meeting-notes"))",
            "title: \(yamlQuoted(input.title))"
        ]
        if let callTitle = trimmed(input.callTitle) {
            frontmatter.append("callTitle: \(yamlQuoted(callTitle))")
        }
        if let calendarTitle = trimmed(input.calendarTitle) {
            frontmatter.append("calendarTitle: \(yamlQuoted(calendarTitle))")
        }
        frontmatter += [
            "date: \(dateFormatter.string(from: input.startDate))",
            "start: \(dateTimeFormatter.string(from: input.startDate))",
            "end: \(dateTimeFormatter.string(from: input.endDate))",
            "timeZone: \(yamlQuoted(timeZone.identifier))"
        ]
        let speakers = input.speakers.compactMap { trimmed($0) }
        if !speakers.isEmpty {
            frontmatter.append("speakers:")
            frontmatter += speakers.map { "  - \(yamlQuoted($0))" }
        }
        frontmatter += [
            "sourceAudio: \(yamlQuoted(input.audioURL.path))",
            "template: \(yamlQuoted(input.templateName))",
            "aiStatus: \(yamlQuoted(input.notes == nil ? "failed" : "ok"))",
            "---"
        ]

        let heading = input.title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var markdown = frontmatter.joined(separator: "\n")
        markdown += "\n\n# \(heading.isEmpty ? "Aufnahme" : heading)\n"
        markdown += "\nAudio: [\(markdownLinkText(input.audioURL.lastPathComponent))](\(input.audioURL.absoluteString))\n"
        markdown += "\n## Notizen\n\n"
        if let notes = input.notes {
            markdown += notes + "\n"
        } else {
            let reason = (input.failure ?? "Unbekannter Fehler")
                .components(separatedBy: .newlines)
                .joined(separator: " ")
            markdown += "> [!warning] KI-Aufbereitung fehlgeschlagen\n> \(reason)\n"
        }
        markdown += "\n## Transkript\n\n"
        markdown += input.transcript.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        return markdown
    }

    /// A double-quoted YAML scalar. Besides backslashes, quotes and line breaks it escapes
    /// every character YAML does not allow there unescaped or reads as a line break
    /// (control characters, NEL, the Unicode line and paragraph separators), so names and
    /// titles from calendars, apps or the LLM cannot break the frontmatter.
    static func yamlQuoted(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                let code = scalar.value
                if code < 0x20 || (0x7F ... 0x9F).contains(code) || [0x2028, 0x2029, 0xFFFE, 0xFFFF].contains(code) {
                    escaped += String(format: "\\u%04X", code)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }

    static func markdownLinkText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func makeDateFormatter(timeZone: TimeZone, format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
