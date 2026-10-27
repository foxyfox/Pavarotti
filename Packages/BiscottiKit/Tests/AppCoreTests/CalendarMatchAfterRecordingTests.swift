import BiscottiTestSupport
import Calendar
import DataStore
import Foundation
import Testing
@testable import AppCore

/// Pavarotti: a recording started without a calendar event is linked to its event
/// when it stops.
@Suite("AppCore -- calendar event after recording")
struct CalendarMatchAfterRecordingTests {
    /// A meeting-like event that started 5 minutes ago and runs another 25.
    private static func standup() -> EKEventDTO {
        let now = Date()
        return EKEventDTO(
            eventIdentifier: "ev-standup", calendarItemIdentifier: "ci-standup",
            calendarItemExternalIdentifier: "ext-standup", occurrenceDate: now.addingTimeInterval(-300),
            title: "Standup", startDate: now.addingTimeInterval(-300), endDate: now.addingTimeInterval(1500),
            isAllDay: false, location: "https://zoom.us/j/123", url: nil, timeZone: nil, notes: nil,
            status: nil, availability: nil, calendarIdentifier: "cal-1", calendarTitle: "Work",
            calendarColorHex: "#0066CC", calendarSourceTitle: "iCloud", birthdayContactIdentifier: nil,
            attendeeCount: 3, attendees: [], organizer: nil
        )
    }

    /// A fixture whose calendar has the standup, without `onLaunch`, so recording
    /// starts without an event.
    @MainActor
    private static func fixture(auth: CalendarAuthStatus = .authorized) throws -> CoreFixture {
        let dto = standup()
        return try makeCoreFixture(
            calendarAuthStatus: auth,
            calendarEventDTOs: [dto],
            calendarRefreshResult: dto,
            testName: "CalendarMatchAfterRecording"
        )
    }

    @Test("A recording without an event gets the matching one when it stops")
    @MainActor
    func linksOnStop() async throws {
        let fix = try Self.fixture()
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let meetingID = try #require(fix.core.recording.state.meetingID)
        #expect(try await fix.store.meetingDetail(id: meetingID)?.calendar == nil)

        _ = await fix.core.stopRecording()

        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.calendar?.title == "Standup")
        #expect(detail?.title == "Standup")
    }

    @Test("An event the user removed is not linked again")
    @MainActor
    func keepsUserUnlink() async throws {
        let fix = try Self.fixture()
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let meetingID = try #require(fix.core.recording.state.meetingID)
        await fix.core.correctAssociation(meetingID: meetingID, eventKey: nil)

        _ = await fix.core.stopRecording()

        #expect(try await fix.store.meetingDetail(id: meetingID)?.calendar == nil)
    }

    @Test("Without calendar access nothing is linked")
    @MainActor
    func needsCalendarAccess() async throws {
        let fix = try Self.fixture(auth: .denied)
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let meetingID = try #require(fix.core.recording.state.meetingID)

        _ = await fix.core.stopRecording()

        #expect(try await fix.store.meetingDetail(id: meetingID)?.calendar == nil)
    }
}
