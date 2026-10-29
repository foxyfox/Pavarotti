@preconcurrency import AVFoundation
import DataStore
import Foundation
import Testing
import Transcription
@testable import Intelligence

/// Pavarotti: the speaker on the microphone track is the user.
@Suite("Recorder speaker")
struct RecorderSpeakerTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "recorder-speaker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // MARK: - Helpers

    private static func segment(_ speakerID: Int, from start: Double, to end: Double) -> SegmentData {
        SegmentData(
            id: UUID(), speakerID: speakerID, speakerLabel: "Speaker \(speakerID)",
            startTime: start, endTime: end, text: "Hallo"
        )
    }

    /// Energy frames that are loud while `loud` covers them and nearly silent otherwise.
    private static func energies(seconds: Double, loud: [ClosedRange<Double>]) -> [Double] {
        let count = Int(seconds / RecorderSpeaker.frameSeconds)
        return (0 ..< count).map { frame in
            let time = Double(frame) * RecorderSpeaker.frameSeconds
            return loud.contains { $0.contains(time) } ? 100 : 1
        }
    }

    /// A mono 24 kHz file that holds a 0.5 tone while `loud` covers it, silence otherwise.
    private func writeTrack(_ name: String, seconds: Double, loud: [ClosedRange<Double>]) throws -> URL {
        let url = folder.appending(path: name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1))
        let frames = AVAudioFrameCount(seconds * 24000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData?[0])
        for index in 0 ..< Int(frames) {
            let time = Double(index) / 24000
            data[index] = loud.contains { $0.contains(time) } ? Float(sin(Double(index) * 0.1) * 0.5) : 0
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private static func spoken(by speakerID: Int, from start: Double, to end: Double) -> TranscriptSegment {
        TranscriptSegment(
            speakerID: speakerID, speakerLabel: "Speaker \(speakerID)", startTime: start, endTime: end,
            text: "Hallo", confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
    }

    // MARK: - Finding the speaker

    @Test("the speaker on the microphone, while the others are in the system audio, recorded the meeting")
    func remoteMeeting() {
        let segments = [
            Self.segment(0, from: 0, to: 6), Self.segment(1, from: 6, to: 12), Self.segment(0, from: 12, to: 18)
        ]
        let mic = Self.energies(seconds: 18, loud: [0 ... 6, 12 ... 18])
        let system = Self.energies(seconds: 18, loud: [6 ... 12])

        let shares = RecorderSpeaker.shares(of: segments, mic: mic, system: system)

        #expect(RecorderSpeaker.recorder(in: shares) == 0)
        #expect((shares[1]?.micShare ?? 1) < 0.1)
        #expect(shares[0]?.seconds == 12)
    }

    @Test("people sharing the microphone name nobody")
    func roomMeeting() {
        let segments = [Self.segment(0, from: 0, to: 6), Self.segment(1, from: 6, to: 12)]
        let mic = Self.energies(seconds: 12, loud: [0 ... 12])
        let system = Self.energies(seconds: 12, loud: [])

        #expect(RecorderSpeaker.recorder(in: RecorderSpeaker.shares(of: segments, mic: mic, system: system)) == nil)
    }

    @Test("a speaker who said little does not count, and nobody on the microphone names nobody")
    func shortAndSilent() {
        let mic = Self.energies(seconds: 12, loud: [0 ... 2])
        let system = Self.energies(seconds: 12, loud: [2 ... 12])
        let short = [Self.segment(0, from: 0, to: 2), Self.segment(1, from: 2, to: 12)]

        #expect(RecorderSpeaker.recorder(in: RecorderSpeaker.shares(of: short, mic: mic, system: system)) == nil)
    }

    @Test("a track's energy is summed per tenth of a second")
    func frameEnergies() throws {
        let url = folder.appending(path: "constant.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000))
        buffer.frameLength = 24000
        let data = try #require(buffer.floatChannelData?[0])
        for index in 0 ..< 24000 {
            data[index] = 0.5
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)

        let energies = RecorderSpeaker.frameEnergies(of: url)

        #expect(energies.count == 10)
        #expect(energies.allSatisfy { abs($0 - 600) < 1 })
        #expect(RecorderSpeaker.frameEnergies(of: folder.appending(path: "missing.caf")).isEmpty)
    }

    // MARK: - Naming the user

    @Test("the speaker on the microphone is named as the calendar's user before the AI runs")
    func namesCalendarUser() async throws {
        let store = try DataStore(storage: .inMemory)
        let fixture = try await makeMeeting(in: store)
        let (meetingID, transcriptID, user) = (fixture.meetingID, fixture.transcriptID, fixture.user)

        let detail = try #require(try await store.meetingDetail(id: meetingID))
        let transcript = try #require(try await store.transcript(id: transcriptID))
        let named = await RecorderSpeaker.namingUser(
            meetingID: meetingID, detail: detail, transcript: transcript, human: [:], store: store
        )

        #expect(named.keys.sorted() == [1])
        #expect(named[1]?.id == user)
        let stored = try #require(try await store.transcript(id: transcriptID))
        #expect(stored.speakerAssignments[1]?.id == user)
        // An AI assignment: the user can still change it, and a rerun may.
        let human = try await store.humanSetSpeakerMappings(for: transcriptID)
        #expect(human.isEmpty)
    }

    @Test("a speaker named by hand keeps their name")
    func keepsHumanNames() async throws {
        let store = try DataStore(storage: .inMemory)
        let fixture = try await makeMeeting(in: store)
        let (meetingID, transcriptID) = (fixture.meetingID, fixture.transcriptID)
        let laura = try await store.findOrCreatePerson(name: "Laura", email: nil)
        let other = PersonData(id: laura, name: "Laura")

        let detail = try #require(try await store.meetingDetail(id: meetingID))
        let transcript = try #require(try await store.transcript(id: transcriptID))
        let human = [1: other]
        let named = await RecorderSpeaker.namingUser(
            meetingID: meetingID, detail: detail, transcript: transcript, human: human, store: store
        )

        #expect(named == human)
    }

    @Test("without a calendar user, the user is the person named like the Mac's account")
    func accountPerson() async throws {
        let store = try DataStore(storage: .inMemory)
        let andreas = try await store.findOrCreatePerson(name: "Andreas", email: nil)
        _ = try await store.findOrCreatePerson(name: "Andreas Müller", email: nil)

        let byFirstName = try await RecorderSpeaker.accountPerson(named: "Andreas Fuchs", store: store)
        #expect(byFirstName?.id == andreas)

        let laura = try await RecorderSpeaker.accountPerson(named: " Laura Schmidt ", store: store)
        #expect(laura?.name == "Laura Schmidt")
        let again = try await RecorderSpeaker.accountPerson(named: "Laura Schmidt", store: store)
        #expect(again?.id == laura?.id)
        #expect(try await RecorderSpeaker.accountPerson(named: "  ", store: store) == nil)
    }

    /// A meeting whose speaker 1 talks on the microphone and speaker 0 in the system
    /// audio, with a calendar that marks Andreas as the user.
    private func makeMeeting(in store: DataStore) async throws -> Fixture {
        let meetingID = try await store.createMeeting(title: "Sync")
        try await store.setSnapshot(CalendarSnapshot(compositeKey: "sync|key", title: "Sync"), for: meetingID)
        let user = try await store.findOrCreatePerson(name: "Andreas Fuchs", email: "andreas@example.com")
        try await store.setParticipants([user], organizer: nil, currentUser: user, for: meetingID)

        let segments = [Self.spoken(by: 0, from: 0, to: 6), Self.spoken(by: 1, from: 6, to: 12)]
        let result = TranscriptResult(
            transcriptionMethodId: "v1", language: "de", speakerCount: 2,
            segments: segments, processingDuration: 1
        )
        let transcriptID = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setPreferredTranscript(transcriptID, for: meetingID)

        let mic = try writeTrack("mic.caf", seconds: 12, loud: [6 ... 12])
        let system = try writeTrack("system.caf", seconds: 12, loud: [0 ... 6])
        try await store.attachAudio([
            AudioFileRef(role: .mic, path: mic.path, byteSize: 1, isPresent: true),
            AudioFileRef(role: .system, path: system.path, byteSize: 1, isPresent: true)
        ], to: meetingID)
        return Fixture(meetingID: meetingID, transcriptID: transcriptID, user: user)
    }

    private struct Fixture {
        let meetingID: UUID
        let transcriptID: UUID
        let user: UUID
    }
}
