import BiscottiTestSupport
import DataStore
import Foundation
import Intelligence
import Testing
import Transcription
@testable import AppCore
@testable import MeetingDetailUI

// MARK: - Helpers

/// Speaker 1 talks for ten seconds, speaker 0 for five.
private func twoSpeakerResult() -> TranscriptResult {
    let segments = [
        TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0",
            startTime: 0, endTime: 5, text: "Hello",
            confidence: 0.9, noSpeechProbability: 0.01, words: nil
        ),
        TranscriptSegment(
            speakerID: 1, speakerLabel: "Speaker 1",
            startTime: 5, endTime: 15, text: "Hi, let us start",
            confidence: 0.9, noSpeechProbability: 0.01, words: nil
        )
    ]
    return TranscriptResult(
        transcriptionMethodId: "test-v1", language: "en",
        speakerCount: 2, segments: segments,
        processingDuration: 1.0
    )
}

/// A meeting with the two-speaker transcript and an AI summary.
private struct HeaderFixture {
    let fix: CoreFixture
    let meetingID: UUID
    let transcriptID: UUID

    @MainActor
    static func make(modelDownloaded: Bool = true) async throws -> HeaderFixture {
        let fix = try makeCoreFixture(
            modelDownloaded: modelDownloaded, testName: "HeaderSpeakers"
        )
        let meetingID = try await fix.createMeetingWithAudio()
        let transcriptID = try await fix.store.addTranscript(
            twoSpeakerResult(), vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(transcriptID, for: meetingID)
        try await fix.store.applyGeneratedSummary("Original AI summary", for: meetingID)
        return HeaderFixture(fix: fix, meetingID: meetingID, transcriptID: transcriptID)
    }

    @MainActor
    func loadedViewModel() async -> MeetingDetailViewModel {
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        viewModel.resummaryDelay = .zero
        await viewModel.load()
        return viewModel
    }
}

// MARK: - Speakers in the header

@Suite("Meeting header -- speakers")
@MainActor
struct HeaderSpeakerTests {
    @Test("lists the speakers, who talks most first")
    func ordersByTalkTime() async throws {
        let header = try await HeaderFixture.make()
        defer { header.fix.cleanup() }
        let daniel = try await header.fix.store.findOrCreatePerson(name: "Daniel", email: nil)
        try await header.fix.store.setSpeakerAssignment(
            speakerID: 0, personID: daniel, for: header.transcriptID
        )

        let viewModel = await header.loadedViewModel()

        let speakers = viewModel.headerSpeakers
        #expect(speakers.map(\.speakerID) == [1, 0])
        #expect(speakers.map(\.name) == ["Speaker 1", "Daniel"])
        #expect(speakers.map(\.seconds) == [10, 5])
    }

    @Test("names a speaker without the speaker sheet")
    func assignsFromHeader() async throws {
        let header = try await HeaderFixture.make()
        defer { header.fix.cleanup() }
        let daniel = try await header.fix.store.findOrCreatePerson(name: "Daniel", email: nil)
        let viewModel = await header.loadedViewModel()

        #expect(viewModel.speakerSheetTranscriptID == nil)
        await viewModel.assignSpeaker(speakerID: 1, personID: daniel)

        #expect(viewModel.displayedSpeakerNames[1] == "Daniel")
        let transcript = try await header.fix.store.transcript(id: header.transcriptID)
        #expect(transcript?.speakerAssignments[1]?.name == "Daniel")
    }

    @Test("offers people from the meeting first, then everyone else, each once")
    func choices() async throws {
        let header = try await HeaderFixture.make()
        defer { header.fix.cleanup() }
        let daniel = try await header.fix.store.findOrCreatePerson(name: "Daniel", email: nil)
        _ = try await header.fix.store.findOrCreatePerson(name: "Priya", email: nil)
        try await header.fix.store.setSpeakerAssignment(
            speakerID: 0, personID: daniel, for: header.transcriptID
        )

        let viewModel = await header.loadedViewModel()

        let choices = viewModel.speakerChoices
        #expect(choices.inMeeting.map(\.name) == ["Daniel"])
        #expect(choices.invited.isEmpty)
        #expect(choices.others.map(\.name) == ["Priya"])
    }
}

// MARK: - Summary after a speaker change

@Suite("Meeting header -- summary after a speaker change")
@MainActor
struct ResummaryAfterSpeakerChangeTests {
    @Test("writes the summary again after a speaker is named")
    func resummarizes() async throws {
        let header = try await HeaderFixture.make()
        defer { header.fix.cleanup() }
        let daniel = try await header.fix.store.findOrCreatePerson(name: "Daniel", email: nil)
        let viewModel = await header.loadedViewModel()

        await viewModel.assignSpeaker(speakerID: 1, personID: daniel)
        let task = try #require(viewModel.resummaryTask)
        await task.value

        #expect(header.fix.core.intelligence.jobs[header.meetingID] == .completed)
        let detail = try await header.fix.store.meetingDetail(id: header.meetingID)
        #expect(detail?.summary != "Original AI summary")
    }

    @Test("waits until the speaker sheet closes")
    func waitsForSheet() async throws {
        let header = try await HeaderFixture.make()
        defer { header.fix.cleanup() }
        let daniel = try await header.fix.store.findOrCreatePerson(name: "Daniel", email: nil)
        let viewModel = await header.loadedViewModel()

        await viewModel.openSpeakerSheet(speakerID: 1)
        await viewModel.assignSpeaker(speakerID: 1, personID: daniel)
        #expect(viewModel.resummaryTask == nil)
        #expect(viewModel.resummaryAfterSheet)

        viewModel.closeSpeakerSheet()
        #expect(viewModel.speakerSheetTranscriptID == nil)
        let task = try #require(viewModel.resummaryTask)
        await task.value
        #expect(header.fix.core.intelligence.jobs[header.meetingID] == .completed)
    }

    @Test("leaves a summary the user wrote alone")
    func keepsEditedSummary() async throws {
        let header = try await HeaderFixture.make()
        defer { header.fix.cleanup() }
        try await header.fix.store.setSummary("My own notes", for: header.meetingID)
        let daniel = try await header.fix.store.findOrCreatePerson(name: "Daniel", email: nil)
        let viewModel = await header.loadedViewModel()

        await viewModel.assignSpeaker(speakerID: 1, personID: daniel)

        #expect(viewModel.resummaryTask == nil)
    }

    @Test("does nothing without a model")
    func needsModel() async throws {
        let header = try await HeaderFixture.make(modelDownloaded: false)
        defer { header.fix.cleanup() }
        let daniel = try await header.fix.store.findOrCreatePerson(name: "Daniel", email: nil)
        let viewModel = await header.loadedViewModel()

        await viewModel.assignSpeaker(speakerID: 1, personID: daniel)

        #expect(viewModel.resummaryTask == nil)
    }
}
