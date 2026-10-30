import DataStore
import Foundation

/// Pavarotti: a meeting transcript as the TypeWhisper fork wrote it into notes: one
/// paragraph per utterance, "[mm:ss] Name: Text", separated by blank lines.
public struct MeetingNoteTranscript: Equatable, Sendable {
    public struct Utterance: Equatable, Sendable {
        public var speaker: String
        public var start: TimeInterval
        public var text: String
    }

    public var utterances: [Utterance]

    /// Consecutive segments of one speaker become one utterance; speakers named as the
    /// same person count as one. Assigned speakers go by their person's name, others by
    /// "Sprecher N" (diarization IDs count from 0).
    public init(_ transcript: TranscriptData) {
        var utterances: [Utterance] = []
        var lastSpeaker: String?
        for segment in transcript.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = Self.speakerKey(of: segment, in: transcript)
            if let speaker, speaker == lastSpeaker, let last = utterances.indices.last {
                utterances[last].text += " " + text
                continue
            }
            utterances.append(Utterance(speaker: Self.name(of: segment, in: transcript), start: segment.startTime, text: text))
            lastSpeaker = speaker
        }
        self.utterances = utterances
    }

    /// Every speaker's name once, in order of their first utterance.
    public var speakers: [String] {
        var names: [String] = []
        for utterance in utterances where !names.contains(utterance.speaker) {
            names.append(utterance.speaker)
        }
        return names
    }

    /// The number of words, to leave out accidental recordings.
    public var wordCount: Int {
        utterances.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// "[mm:ss] Name: Text" paragraphs separated by blank lines, without a trailing line
    /// break. Minutes have at least two digits ("[75:12]"), seconds are rounded down.
    public var text: String {
        utterances
            .map { "[\(Self.timestamp($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n\n")
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        return String(format: "%02ld:%02ld", total / 60, total % 60)
    }

    /// Who says the segment: the assigned person, else the diarization speaker. `nil`
    /// without a speaker, so such segments stay apart.
    private static func speakerKey(of segment: SegmentData, in transcript: TranscriptData) -> String? {
        guard let speakerID = segment.speakerID else { return nil }
        if let person = transcript.speakerAssignments[speakerID] {
            return "person-\(person.id.uuidString)"
        }
        return "speaker-\(speakerID)"
    }

    private static func name(of segment: SegmentData, in transcript: TranscriptData) -> String {
        guard let speakerID = segment.speakerID else {
            let label = segment.speakerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? "Unbekannt" : label
        }
        let name = transcript.speakerName(forID: speakerID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Sprecher \(speakerID + 1)" : name
    }
}
