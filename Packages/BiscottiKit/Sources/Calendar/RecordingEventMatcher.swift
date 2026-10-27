import Foundation

/// Pavarotti: finds the calendar event a finished recording belongs to when it was
/// started without one, for example a spontaneous call or a recording started well
/// before its event. Ported from the TypeWhisper fork's meeting matcher.
public enum RecordingEventMatcher {
    /// An event that starts this close to the recording counts with any overlap.
    public static let startTolerance: TimeInterval = 10 * 60
    /// Otherwise it must cover this share of the recording.
    public static let minimumOverlapShare = 0.5
    /// Longer events are blockers or trips, never a meeting.
    public static let maximumEventDuration: TimeInterval = 8 * 60 * 60
    /// Overlaps this close count as equal.
    private static let overlapTolerance: TimeInterval = 1

    private struct Candidate {
        let event: CalendarEvent
        let overlap: TimeInterval
    }

    /// The recording widened by ``startTolerance`` on both sides: where events are searched.
    public static func searchInterval(for recording: DateInterval) -> DateInterval {
        let recording = effective(recording)
        return DateInterval(
            start: recording.start.addingTimeInterval(-startTolerance),
            end: recording.end.addingTimeInterval(startTolerance)
        )
    }

    /// The event the recording most likely belongs to, or `nil`.
    ///
    /// An event must be meeting-like (a conference link or other people), at most
    /// 8 hours long, overlap the recording, and either cover at least half of it or
    /// start within 10 minutes of its start. The largest overlap wins, then the start
    /// closest to the recording's.
    public static func bestMatch(recording: DateInterval, candidates: [CalendarEvent]) -> CalendarEvent? {
        let recording = effective(recording)
        let eligible = candidates.compactMap { event -> Candidate? in
            let length = event.end.timeIntervalSince(event.start)
            guard event.isMeetingLike, length > 0, length <= maximumEventDuration else { return nil }
            let covered = min(event.end, recording.end).timeIntervalSince(max(event.start, recording.start))
            guard covered > 0 else { return nil }
            let startsClose = abs(event.start.timeIntervalSince(recording.start)) <= startTolerance
            guard startsClose || covered >= minimumOverlapShare * recording.duration else { return nil }
            return Candidate(event: event, overlap: covered)
        }
        return eligible.min { first, second in
            if abs(first.overlap - second.overlap) > overlapTolerance {
                return first.overlap > second.overlap
            }
            let firstDistance = abs(first.event.start.timeIntervalSince(recording.start))
            let secondDistance = abs(second.event.start.timeIntervalSince(recording.start))
            if firstDistance != secondDistance {
                return firstDistance < secondDistance
            }
            if first.event.start != second.event.start {
                return first.event.start < second.event.start
            }
            return first.event.id < second.event.id
        }?.event
    }

    /// At least one second long, so a recording without duration still overlaps.
    private static func effective(_ recording: DateInterval) -> DateInterval {
        DateInterval(start: recording.start, end: max(recording.end, recording.start.addingTimeInterval(1)))
    }
}
