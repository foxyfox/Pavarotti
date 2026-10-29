@preconcurrency import AVFoundation
import DataStore
import Foundation
import os

/// Pavarotti: finds the speaker who recorded the meeting. The recording keeps the
/// microphone and the system audio as separate tracks: remote participants come in through
/// the system audio, the user speaks into the microphone. The speaker whose speech is
/// clearly on the microphone track, while everyone else's is not, is the user.
enum RecorderSpeaker {
    /// Seconds per energy frame.
    static let frameSeconds = 0.1
    /// The recorder's share of their speech energy on the microphone at least.
    static let minimumMicShare = 0.75
    /// Every other speaker's share at most, so a room full of people at one microphone
    /// names nobody.
    static let maximumOtherMicShare = 0.5
    /// Speakers who spoke less than this are left out of the comparison.
    static let minimumSpeechSeconds = 5.0

    /// Where one speaker's speech energy is: on the microphone or in the system audio.
    struct Share: Equatable {
        var mic = 0.0
        var system = 0.0
        var seconds = 0.0

        var micShare: Double? {
            mic + system > 0 ? mic / (mic + system) : nil
        }
    }

    /// The speaker who recorded the meeting, from its two tracks; `nil` when the tracks
    /// cannot be read or no speaker clearly stands out. Reads the files off the main thread.
    static func find(in transcript: TranscriptData, mic: URL?, system: URL?) async -> Int? {
        guard let mic, let system else { return nil }
        let segments = transcript.segments
        return await Task.detached(priority: .utility) {
            let micEnergies = frameEnergies(of: mic)
            let systemEnergies = frameEnergies(of: system)
            guard !micEnergies.isEmpty, !systemEnergies.isEmpty else { return nil }
            return recorder(in: shares(of: segments, mic: micEnergies, system: systemEnergies))
        }.value
    }

    /// Each speaker's speech energy on both tracks, over the frames of their segments.
    static func shares(of segments: [SegmentData], mic: [Double], system: [Double]) -> [Int: Share] {
        var shares: [Int: Share] = [:]
        for segment in segments {
            guard let speakerID = segment.speakerID, segment.endTime > segment.startTime else { continue }
            let first = max(0, Int(segment.startTime / frameSeconds))
            let end = max(first, Int((segment.endTime / frameSeconds).rounded(.up)))
            var share = shares[speakerID] ?? Share()
            for frame in first ..< end {
                share.mic += frame < mic.count ? mic[frame] : 0
                share.system += frame < system.count ? system[frame] : 0
            }
            share.seconds += segment.endTime - segment.startTime
            shares[speakerID] = share
        }
        return shares
    }

    /// The one speaker clearly on the microphone, when everyone else is not.
    static func recorder(in shares: [Int: Share]) -> Int? {
        let ranked = shares
            .filter { $0.value.seconds >= minimumSpeechSeconds }
            .compactMap { speakerID, share in share.micShare.map { (speakerID: speakerID, micShare: $0) } }
            .sorted { $0.micShare != $1.micShare ? $0.micShare > $1.micShare : $0.speakerID < $1.speakerID }
        guard let best = ranked.first, best.micShare >= minimumMicShare else { return nil }
        guard ranked.dropFirst().allSatisfy({ $0.micShare <= maximumOtherMicShare }) else { return nil }
        return best.speakerID
    }

    /// The summed squared samples of each ``frameSeconds`` of `url`, channels averaged;
    /// empty when the file cannot be read.
    static func frameEnergies(of url: URL) -> [Double] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let frameLength = max(1, Int(format.sampleRate * frameSeconds))
        let channelCount = Int(format.channelCount)
        guard channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameLength * 100))
        else {
            return []
        }
        var energies: [Double] = []
        var current = 0.0
        var counted = 0
        while (try? file.read(into: buffer)) != nil, buffer.frameLength > 0, let channels = buffer.floatChannelData {
            for index in 0 ..< Int(buffer.frameLength) {
                var sample = 0.0
                for channel in 0 ..< channelCount {
                    sample += Double(channels[channel][index])
                }
                sample /= Double(channelCount)
                current += sample * sample
                counted += 1
                if counted == frameLength {
                    energies.append(current)
                    current = 0
                    counted = 0
                }
            }
        }
        if counted > 0 {
            energies.append(current)
        }
        return energies
    }
}

// MARK: - The user as a person

extension RecorderSpeaker {
    /// The person who is the user: the calendar's current user of this meeting, else the
    /// one the calendar marks most often, else the person named like the Mac's account,
    /// created when there is none. `nil` without any of these.
    static func userPerson(for detail: MeetingDetailData, store: DataStore) async throws -> PersonData? {
        let invitees = [detail.calendar?.organizer].compactMap(\.self) + (detail.calendar?.attendees ?? [])
        if let user = invitees.first(where: \.isCurrentUser) {
            return user
        }
        if let personID = try await store.mostFrequentCurrentUserPersonID() {
            return try await store.people(ids: [personID])[personID]
        }
        return try await accountPerson(named: NSFullUserName(), store: store)
    }

    /// The person named like the Mac's account (`name`): one with the full name, else one
    /// named only by its first name, else a new one.
    static func accountPerson(named name: String, store: DataStore) async throws -> PersonData? {
        let fullName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullName.isEmpty else { return nil }
        var candidates = [fullName]
        if let firstName = fullName.split(separator: " ").first.map(String.init), firstName != fullName {
            candidates.append(firstName)
        }
        for candidate in candidates {
            // `personID(matchingName:)` also takes a unique first name; only an exact name counts here.
            guard let personID = try await store.personID(matchingName: candidate),
                  let person = try await store.people(ids: [personID])[personID],
                  person.name.compare(candidate, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            else { continue }
            return person
        }
        let created = try await store.findOrCreatePerson(name: fullName, email: nil)
        return try await store.people(ids: [created])[created]
    }
}

// MARK: - Naming the user before the AI runs

extension RecorderSpeaker {
    private static let logger = Logger(subsystem: "de.foxagon.pavarotti", category: "Voiceprints")

    /// The speakers named by hand, plus the user on the microphone track while some
    /// speaker is still unnamed.
    static func speakerMappings(
        meetingID: UUID, detail: MeetingDetailData, transcript: TranscriptData, store: DataStore
    ) async -> [Int: PersonData] {
        let human = await (try? store.humanSetSpeakerMappings(for: transcript.id)) ?? [:]
        let speakers = Set(transcript.segments.compactMap(\.speakerID))
        guard !speakers.subtracting(human.keys).isEmpty else { return human }
        return await namingUser(meetingID: meetingID, detail: detail, transcript: transcript, human: human, store: store)
    }

    /// Names the speaker who recorded the meeting as the user, as an AI assignment, when
    /// nobody named that speaker or the user by hand. Returns `human` with them added, so
    /// the AI keeps the assignment and the summary uses the name.
    static func namingUser(
        meetingID: UUID, detail: MeetingDetailData, transcript: TranscriptData,
        human: [Int: PersonData], store: DataStore
    ) async -> [Int: PersonData] {
        guard let refs = try? await store.audioFileRefs(meetingID: meetingID),
              let speakerID = await find(in: transcript, mic: refs.mic, system: refs.system),
              human[speakerID] == nil
        else {
            return human
        }
        do {
            guard let user = try await userPerson(for: detail, store: store),
                  !human.values.contains(where: { $0.id == user.id })
            else {
                return human
            }
            try await store.setSpeakerAssignments([speakerID: user.id], for: transcript.id)
            logger.notice("Speaker \(speakerID, privacy: .public) recorded the meeting on the microphone; named as the user")
            var named = human
            named[speakerID] = user
            return named
        } catch {
            logger.error("Could not name the user: \(error.localizedDescription, privacy: .public)")
            return human
        }
    }
}
