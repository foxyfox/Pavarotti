import Calendar
import DataStore
import Foundation
import MeetingCatalog
import Testing

/// 10:00 on a fixed day; the recording runs 10:00–10:30 unless a test says otherwise.
private let base = Date(timeIntervalSince1970: 1_760_000_000)

private func time(_ minutes: Double) -> Date {
    base.addingTimeInterval(minutes * 60)
}

private let recording = DateInterval(start: time(0), end: time(30))

private func event(_ id: String, from start: Double, to end: Double, meetingLike: Bool = true) -> CalendarEvent {
    CalendarEvent(
        id: id, title: id, start: time(start), end: time(end),
        conferencePlatform: nil, conferenceURL: nil, attendeeCount: meetingLike ? 3 : 0,
        calendarTitle: "Work", calendarColorHex: "#0066CC", isMeetingLike: meetingLike
    )
}

private func match(_ candidates: [CalendarEvent], to interval: DateInterval = recording) -> String? {
    RecordingEventMatcher.bestMatch(recording: interval, candidates: candidates)?.id
}

@Suite("RecordingEventMatcher")
struct RecordingEventMatcherTests {
    @Test("An event covering the recording matches, a blocker does not")
    func covering() {
        #expect(match([event("sync", from: 0, to: 30)]) == "sync")
        #expect(match([event("focus", from: 0, to: 30, meetingLike: false)]) == nil)
    }

    @Test("An event starting within 10 minutes counts with any overlap")
    func startsClose() {
        #expect(match([event("late", from: 8, to: 12)]) == "late")
        #expect(match([event("too late", from: 20, to: 60)]) == nil)
    }

    @Test("Otherwise an event must cover half the recording")
    func halfCovered() {
        #expect(match([event("long", from: -60, to: 20)]) == "long")
        #expect(match([event("short", from: -60, to: 10)]) == nil)
    }

    @Test("Events without overlap or longer than 8 hours never match")
    func excluded() {
        #expect(match([event("before", from: -40, to: -5)]) == nil)
        #expect(match([event("day", from: -120, to: 9 * 60)]) == nil)
    }

    @Test("The largest overlap wins, then the closest start")
    func ranking() {
        #expect(match([event("partial", from: -60, to: 20), event("full", from: 5, to: 60)]) == "full")
        #expect(match([event("early", from: -5, to: 60), event("exact", from: 0, to: 60)]) == "exact")
    }

    @Test("A recording without duration still matches the event it started in")
    func instant() {
        let instant = DateInterval(start: time(2), duration: 0)
        #expect(match([event("sync", from: 0, to: 30)], to: instant) == "sync")
        #expect(RecordingEventMatcher.searchInterval(for: instant).start == time(-8))
    }
}

@Suite("CalendarService — eventMatchingRecording")
struct EventMatchingRecordingTests {
    private static func dto(_ id: String, status: String? = nil, userStatus: String = "accepted") -> EKEventDTO {
        let user = AttendeeDTO(
            name: "Me", participantURL: URL(string: "mailto:me@example.com"),
            isCurrentUser: true, role: "required", status: userStatus, type: "person"
        )
        let other = AttendeeDTO(
            name: "Alice", participantURL: URL(string: "mailto:alice@example.com"),
            isCurrentUser: false, role: "required", status: "accepted", type: "person"
        )
        return EKEventDTO(
            eventIdentifier: id, calendarItemIdentifier: "ci-\(id)", calendarItemExternalIdentifier: "ext-\(id)",
            occurrenceDate: time(0), title: id, startDate: time(0), endDate: time(30),
            isAllDay: false, location: nil, url: nil, timeZone: nil, notes: nil,
            status: status, availability: nil, calendarIdentifier: "cal-1", calendarTitle: "Work",
            calendarColorHex: "#0066CC", calendarSourceTitle: "iCloud", birthdayContactIdentifier: nil,
            attendeeCount: 2, attendees: [user, other], organizer: nil
        )
    }

    @MainActor
    private static func service(_ dtos: [EKEventDTO]) throws -> CalendarService {
        var provider = FakeEventStoreProvider()
        provider.eventList = dtos
        provider.refreshResult = dtos.first
        return try CalendarService(store: DataStore(storage: .inMemory), catalog: BundledMeetingCatalog(), provider: provider)
    }

    @Test("The matching event can be linked through its snapshot")
    @MainActor
    func linksMatch() async throws {
        let service = try Self.service([Self.dto("sync")])
        let event = try #require(await service.eventMatchingRecording(recording))
        #expect(event.title == "sync")
        #expect(await service.snapshot(forKey: event.id) != nil)
    }

    @Test("Declined and canceled events never match")
    @MainActor
    func skipsDeclinedAndCanceled() async throws {
        let declined = try Self.service([Self.dto("declined", userStatus: "declined")])
        #expect(await declined.eventMatchingRecording(recording) == nil)
        let canceled = try Self.service([Self.dto("canceled", status: "canceled")])
        #expect(await canceled.eventMatchingRecording(recording) == nil)
    }
}
