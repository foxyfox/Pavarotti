import Calendar
import Foundation

/// Pavarotti: a recording started without a calendar event (a spontaneous call, or a
/// recording started well before its event) is linked to the event it most likely
/// belongs to once it stops, like the TypeWhisper fork did.
extension AppCore {
    /// Links `meetingID` to the best-matching calendar event when it has none and the
    /// user did not remove one.
    func linkCalendarEventAfterRecording(_ meetingID: UUID) async {
        guard calendar.auth == .authorized, !calendarUnlinkedMeetingIDs.contains(meetingID),
              let detail = try? await store.meetingDetail(id: meetingID), detail.calendar == nil
        else { return }
        let end = detail.endDate ?? detail.date.addingTimeInterval(detail.recordingDuration ?? 0)
        let recording = DateInterval(start: detail.date, end: max(end, detail.date))
        guard let event = await calendar.eventMatchingRecording(recording) else { return }
        await correctAssociation(meetingID: meetingID, eventKey: event.id)
    }
}
