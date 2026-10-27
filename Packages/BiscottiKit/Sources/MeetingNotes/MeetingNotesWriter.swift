import DataStore
import Foundation

/// Pavarotti: writes a meeting's Markdown note into the notes folder.
///
/// Each meeting has one note. A later run (new summary, new speaker names, new title)
/// rewrites that file and renames it when the title changed, so the folder never holds
/// stale copies. The app is the source of truth: edits made to the file are replaced.
public struct MeetingNotesWriter: Sendable {
    /// Shorter transcripts are accidental recordings, not meetings worth a note.
    public static let minimumWords = 20

    public enum Outcome: Equatable, Sendable {
        case written(URL)
        case skipped(reason: String)
    }

    private let store: MeetingNotesSettingsStore
    private let timeZone: TimeZone

    public init(store: MeetingNotesSettingsStore = MeetingNotesSettingsStore(), timeZone: TimeZone = .current) {
        self.store = store
        self.timeZone = timeZone
    }

    /// Writes the note of `detail`. `audioURL` is the recording the note links to;
    /// `failure` says why there is no summary when there is none.
    public func write(_ detail: MeetingDetailData, audioURL: URL?, failure: String?) throws -> Outcome {
        let settings = store.load()
        guard settings.isEnabled else { return .skipped(reason: "Meeting notes are off.") }
        guard let transcript = detail.preferredTranscript else { return .skipped(reason: "No transcript.") }
        let spoken = MeetingNoteTranscript(transcript)
        guard spoken.wordCount >= Self.minimumWords else {
            return .skipped(reason: "Transcript too short (\(spoken.wordCount) words).")
        }
        guard let audioURL else { return .skipped(reason: "No recording.") }

        let input = Self.input(for: detail, transcript: spoken, audioURL: audioURL, failure: failure, settings: settings)
        let markdown = MeetingNoteMarkdown.render(input, timeZone: timeZone)
        let url = try place(note: detail.id, title: input.title, start: input.startDate, in: settings.folder)
        try Data(markdown.utf8).write(to: url, options: .atomic)
        store.setNoteURL(url, for: detail.id)
        return .written(url)
    }

    /// The note's content, without touching the disk.
    static func input(
        for detail: MeetingDetailData,
        transcript: MeetingNoteTranscript,
        audioURL: URL,
        failure: String?,
        settings: MeetingNotesSettings
    ) -> MeetingNoteMarkdown.Input {
        let start = detail.date
        let length = detail.recordingDuration ?? detail.duration ?? 0
        let end = detail.endDate ?? start.addingTimeInterval(max(0, length))
        let summary = strippingOuterCodeFence(detail.summary).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = detail.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarTitle = detail.calendar?.title ?? detail.calendar?.conferencePlatform
        return MeetingNoteMarkdown.Input(
            title: title.isEmpty ? "Aufnahme \(displayDate(start))" : title,
            startDate: start,
            endDate: max(start, end),
            audioURL: audioURL,
            templateName: settings.templateName,
            notes: summary.isEmpty ? nil : summary,
            failure: summary.isEmpty ? (failure ?? "Es gibt noch keine KI-Zusammenfassung.") : nil,
            transcript: transcript.text,
            callTitle: calendarTitle,
            speakers: transcript.speakers
        )
    }

    /// The file for the note: the meeting's earlier note, renamed when its title changed,
    /// or a new file.
    private func place(note meetingID: UUID, title: String, start: Date, in folder: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let baseName = MeetingNoteFileName.baseName(title: title, start: start, timeZone: timeZone)
        guard let existing = store.noteURL(for: meetingID), fileManager.fileExists(atPath: existing.path) else {
            return MeetingNoteFileName.availableURL(in: folder, baseName: baseName)
        }
        let sameFolder = existing.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
        let existingBase = existing.deletingPathExtension().lastPathComponent
        if sameFolder, existingBase == baseName || existingBase.hasPrefix(baseName + " ") {
            return existing
        }
        let renamed = MeetingNoteFileName.availableURL(in: folder, baseName: baseName)
        try fileManager.moveItem(at: existing, to: renamed)
        return renamed
    }

    /// Some models wrap the whole answer in a ```markdown fence despite the prompt.
    static func strippingOuterCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count > 6 else { return text }
        var lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 2 else { return text }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter.string(from: date)
    }
}
