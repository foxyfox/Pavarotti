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

    // TODO: Also rewrite the note when speakers are renamed or the summary is edited
    // by hand; today only an AI run updates it.
    /// Writes or rewrites the note of `meetingID` in the background.
    func writeMeetingNote(meetingID: UUID) {
        let failure: String? = if case let .failed(message) = intelligence.jobs[meetingID] {
            message
        } else {
            nil
        }
        let store = store
        Task.detached(priority: .utility) {
            await AppCore.writeNote(meetingID: meetingID, failure: failure, store: store)
        }
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
