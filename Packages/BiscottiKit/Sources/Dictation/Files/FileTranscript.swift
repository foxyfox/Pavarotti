import Foundation

/// The transcript of an audio or video file.
public struct FileTranscript: Equatable, Sendable {
    /// A new paragraph starts after a pause this long (seconds)…
    static let paragraphPause: TimeInterval = 2
    /// …or once a paragraph is this long.
    static let paragraphLength: TimeInterval = 60

    public var source: URL
    /// The length of the audio in seconds.
    public var duration: TimeInterval
    /// ISO 639-1 code of the main language, `nil` when unknown.
    public var language: String?
    /// The passages in order, in seconds from the start of the file.
    public var passages: [TimedText]
    public var createdAt: Date

    public init(source: URL, duration: TimeInterval, language: String?, passages: [TimedText], createdAt: Date) {
        self.source = source
        self.duration = duration
        self.language = language
        self.passages = passages
        self.createdAt = createdAt
    }

    /// The file name without its extension.
    public var title: String {
        source.deletingPathExtension().lastPathComponent
    }

    /// The suggested name of the Markdown file.
    public var markdownFileName: String {
        "\(title).md"
    }

    /// The passages joined into paragraphs. A new one starts after a pause of two seconds
    /// or once a paragraph is a minute long.
    public var paragraphs: [TimedText] {
        var result: [TimedText] = []
        for passage in passages {
            let text = passage.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = result.last,
               passage.start - last.end < Self.paragraphPause,
               passage.start - last.start < Self.paragraphLength
            {
                last.text += " " + text
                last.end = passage.end
                result[result.count - 1] = last
            } else {
                result.append(TimedText(start: passage.start, end: passage.end, text: text))
            }
        }
        return result
    }

    /// The paragraphs as "[mm:ss] Text", separated by blank lines, like the meeting notes.
    public var transcriptText: String {
        paragraphs
            .map { "[\(Self.timestamp($0.start))] \($0.text)" }
            .joined(separator: "\n\n")
    }

    /// A Markdown note in the format of the meeting notes: YAML frontmatter, a heading,
    /// a link to the file and the transcript.
    public func markdown(timeZone: TimeZone = .current) -> String {
        var frontmatter = [
            "---",
            "type: \(Self.yamlQuoted("transcript"))",
            "title: \(Self.yamlQuoted(title))",
            "date: \(Self.dateString(createdAt, timeZone: timeZone))",
            "sourceAudio: \(Self.yamlQuoted(source.path))",
            "duration: \(Self.yamlQuoted(Self.timestamp(duration)))"
        ]
        if let language, !language.isEmpty {
            frontmatter.append("language: \(Self.yamlQuoted(language))")
        }
        frontmatter.append("---")

        let heading = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var markdown = frontmatter.joined(separator: "\n")
        markdown += "\n\n# \(heading.isEmpty ? "Transkript" : heading)\n"
        markdown += "\nAudio: [\(Self.markdownLinkText(source.lastPathComponent))](\(source.absoluteString))\n"
        markdown += "\n## Transkript\n\n"
        markdown += transcriptText + "\n"
        return markdown
    }

    /// "mm:ss" with at least two minute digits ("75:12" after an hour); seconds are
    /// rounded down, negative or invalid times give "00:00".
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        return String(format: "%02ld:%02ld", total / 60, total % 60)
    }

    private static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// A double-quoted YAML scalar. Besides backslashes, quotes and line breaks it escapes
    /// every character YAML does not allow there unescaped or reads as a line break, so a
    /// file name cannot break the frontmatter.
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
}
