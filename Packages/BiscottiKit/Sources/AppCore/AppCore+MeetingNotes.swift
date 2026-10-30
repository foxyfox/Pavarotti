import DataStore
import Foundation
import Intelligence
import MeetingNotes
import os

/// Pavarotti: Markdown notes for meetings, in the format and folder of Andreas's
/// TypeWhisper fork. A note is written after every AI run, automatic or manual, and
/// also when the run had no model or AI was off, so the transcript always lands there.
public extension AppCore {
    /// Wires the notes up: takes over the TypeWhisper setup once and writes a note
    /// whenever an AI run finishes. Called by the app at launch, not by `onLaunch`, so
    /// tests never write into the user's notes folder.
    func startMeetingNotes() async {
        intelligence.onRunFinished = { [weak self] meetingID in
            self?.writeMeetingNote(meetingID: meetingID)
        }
        await importTypeWhisperNotesSetup()
    }

    /// Writes or rewrites the note of `meetingID` in the background.
    func writeMeetingNote(meetingID: UUID) {
        let failure: String? = if case let .failed(message) = intelligence.jobs[meetingID] {
            message
        } else {
            nil
        }
        let store = store
        MeetingNoteQueue.shared.enqueue {
            await AppCore.writeNote(meetingID: meetingID, failure: failure, store: store)
        }
    }

    /// Rewrites the note of `meetingID` after the user changed what it shows: the title,
    /// the summary or a speaker's name. Only a meeting that has a note gets one here;
    /// before its first AI run, that run writes the note.
    func meetingNoteSourceChanged(meetingID: UUID) {
        guard MeetingNotesSettingsStore().noteURL(for: meetingID) != nil else { return }
        writeMeetingNote(meetingID: meetingID)
    }

    /// Where Finder shows the note of `meetingID`: the note file once it is written, else
    /// the notes folder while notes are on and the folder exists. `nil` when neither.
    func meetingNoteLocation(meetingID: UUID) -> MeetingNoteLocation? {
        let settingsStore = MeetingNotesSettingsStore()
        if let file = settingsStore.existingNoteURL(for: meetingID) {
            return .file(file)
        }
        let settings = settingsStore.load()
        guard settings.isEnabled, FileManager.default.fileExists(atPath: settings.folder.path) else { return nil }
        return .folder(settings.folder)
    }

    /// Takes over TypeWhisper's notes folder and "Besprechungsnotizen" prompt, once. A
    /// summary prompt the user already changed stays.
    func importTypeWhisperNotesSetup() async {
        let settingsStore = MeetingNotesSettingsStore()
        var settings = settingsStore.load()
        guard !settings.checkedTypeWhisper else { return }
        settings.checkedTypeWhisper = true
        defer { settingsStore.save(settings) }

        guard let setup = TypeWhisperNotesImport.setup() else { return }
        if let folder = setup.folderPath {
            settings.folderPath = folder
        }
        if let workflow = setup.workflow, let prompt = workflow.summaryPrompt {
            let current = await (try? store.settings())?.summaryPrompt ?? ""
            if current.isEmpty {
                try? await saveSummaryPrompt(prompt)
                settings.templateName = workflow.name
            }
        }
    }

    private nonisolated static func writeNote(meetingID: UUID, failure: String?, store: DataStore) async {
        let logger = Logger(subsystem: "de.foxagon.pavarotti", category: "MeetingNotes")
        do {
            guard let detail = try await store.meetingDetail(id: meetingID) else { return }
            let audio = try await store.audioFileRefs(meetingID: meetingID)
            let aiEnabled = await (try? store.settings())?.aiAnalysisEnabled ?? true
            let reason = failure ?? (aiEnabled ? nil : "Die KI-Analyse ist in den Einstellungen ausgeschaltet.")
            let outcome = try MeetingNotesWriter().write(detail, audioURL: audio.mic ?? audio.system, failure: reason)
            switch outcome {
            case let .written(url):
                logger.info("Meeting note written: \(url.path, privacy: .private)")
            case let .skipped(why):
                logger.info("No meeting note: \(why, privacy: .public)")
            }
        } catch {
            logger.error("Meeting note failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Pavarotti: what "Reveal note in Finder" shows.
public enum MeetingNoteLocation: Equatable, Sendable {
    /// The meeting's note.
    case file(URL)
    /// The notes folder, before the meeting's note is written.
    case folder(URL)
}
