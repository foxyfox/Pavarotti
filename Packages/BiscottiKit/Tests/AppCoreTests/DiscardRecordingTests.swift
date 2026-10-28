import BiscottiTestSupport
import Foundation
import Testing
@testable import AppCore

// Pavarotti: throwing away a recording of a meeting that did not take place.

@Suite("AppCore -- discarding a recording")
struct DiscardRecordingTests {
    @Test("discarding stops the recording and deletes the meeting with its audio")
    @MainActor
    func discardDeletesMeeting() async throws {
        let fix = try makeCoreFixture(useFakeScheduler: true, testName: "DiscardRecording")
        defer { fix.cleanup() }
        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        await fix.core.startRecording()
        guard case let .recording(meetingID) = fix.core.runState else {
            Issue.record("Expected recording state")
            return
        }
        let audio = try await fix.store.audioFilePaths(meetingID: meetingID)

        let discarded = await fix.core.discardRecording()

        #expect(discarded == meetingID)
        #expect(fix.core.runState == .idle)
        #expect(fix.core.route == .home)
        #expect(fix.core.recording.state.isRecording == false)
        #expect(fix.core.autoStop == nil)
        #expect(!fix.core.summaries.contains { $0.id == meetingID })
        #expect(try await fix.store.meetingDetail(id: meetingID) == nil)
        #expect(audio.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    @Test("discarding without a recording changes nothing")
    @MainActor
    func discardWithoutRecording() async throws {
        let fix = try makeCoreFixture(useFakeScheduler: true, testName: "DiscardRecording")
        defer { fix.cleanup() }
        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        #expect(await fix.core.discardRecording() == nil)
        #expect(fix.core.runState == .idle)
    }
}
