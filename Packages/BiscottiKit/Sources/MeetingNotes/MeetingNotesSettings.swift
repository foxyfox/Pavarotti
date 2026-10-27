import Foundation

/// Pavarotti: what the user can set about meeting notes. Stored as JSON in user defaults,
/// separate from Biscotti's database, like the dictation settings.
public struct MeetingNotesSettings: Codable, Equatable, Sendable {
    /// Whether a note is written after every transcribed meeting.
    public var isEnabled = true
    /// Folder for the notes; `nil` uses ``MeetingNotesSettings/defaultFolder``.
    public var folderPath: String?
    /// The name of the summary prompt, written to the note's `template` field.
    public var templateName = MeetingNotesSettings.defaultTemplateName
    /// Whether the folder and prompt were looked up in TypeWhisper already.
    public var checkedTypeWhisper = false

    public static let defaultTemplateName = "Zusammenfassung"

    /// `~/Documents/Meeting-Notizen`.
    public static var defaultFolder: URL {
        URL.documentsDirectory.appending(path: "Meeting-Notizen", directoryHint: .isDirectory)
    }

    public init() {}

    public var folder: URL {
        folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        folderPath = try? container.decodeIfPresent(String.self, forKey: .folderPath)
        templateName = (try? container.decodeIfPresent(String.self, forKey: .templateName)) ?? Self.defaultTemplateName
        checkedTypeWhisper = (try? container.decodeIfPresent(Bool.self, forKey: .checkedTypeWhisper)) ?? false
    }
}

/// Loads and saves ``MeetingNotesSettings`` and remembers which file holds each meeting's
/// note, so a new run rewrites that file instead of adding another.
public final class MeetingNotesSettingsStore: @unchecked Sendable {
    public static let settingsKey = "pavarotti.meetingNotes.settings"
    public static let filesKey = "pavarotti.meetingNotes.files"
    // UserDefaults is thread-safe; the lock keeps read-modify-write of the file index whole.
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> MeetingNotesSettings {
        guard let data = defaults.data(forKey: Self.settingsKey),
              let settings = try? JSONDecoder().decode(MeetingNotesSettings.self, from: data)
        else {
            return MeetingNotesSettings()
        }
        return settings
    }

    public func save(_ settings: MeetingNotesSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }

    /// The note file written for `meetingID`, if any.
    public func noteURL(for meetingID: UUID) -> URL? {
        lock.withLock { files()[meetingID.uuidString] }.map { URL(fileURLWithPath: $0) }
    }

    public func setNoteURL(_ url: URL?, for meetingID: UUID) {
        lock.withLock {
            var files = files()
            files[meetingID.uuidString] = url?.path
            defaults.set(files, forKey: Self.filesKey)
        }
    }

    private func files() -> [String: String] {
        defaults.dictionary(forKey: Self.filesKey) as? [String: String] ?? [:]
    }
}
