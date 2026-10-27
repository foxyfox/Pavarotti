import Foundation
import SQLite3

/// Pavarotti: takes over the meeting notes setup of Andreas's TypeWhisper fork: the notes
/// folder and the instructions of the workflow that wrote the notes ("Besprechungsnotizen").
///
/// Reads TypeWhisper's preferences and, read-only, its workflow store. Nothing is written
/// back to TypeWhisper.
public enum TypeWhisperNotesImport {
    public static let preferencesDomain = "com.typewhisper.mac"
    static let folderPathKey = "recorderMeetingNotesOutputFolderPath"
    static let workflowIDKey = "recorderMeetingNotesWorkflowId"

    /// The workflow store of a release build of TypeWhisper.
    public static var workflowStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "TypeWhisper/workflows.store", directoryHint: .notDirectory)
    }

    /// What TypeWhisper had set up for meeting notes.
    public struct Setup: Equatable, Sendable {
        /// The notes folder, `nil` when TypeWhisper wrote notes next to the recordings.
        public var folderPath: String?
        /// The chosen workflow, `nil` when TypeWhisper used its built-in template.
        public var workflow: Workflow?
    }

    /// A workflow's own instructions, without TypeWhisper's built-in template text.
    public struct Workflow: Equatable, Sendable {
        public var name: String
        public var instruction: String
        public var settings: [String: String]
        public var fineTuning: String

        /// The workflow's instructions as a summary prompt for meeting notes. The user's
        /// text decides the content; the frame keeps the answer Markdown only.
        public var summaryPrompt: String? {
            var parts: [String] = []
            let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedInstruction.isEmpty {
                parts.append(trimmedInstruction)
            }
            let extra = settings
                .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { "- \($0.key): \($0.value)" }
            if !extra.isEmpty {
                parts.append("Additional settings:\n" + extra.joined(separator: "\n"))
            }
            let trimmedFineTuning = fineTuning.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedFineTuning.isEmpty {
                parts.append("Fine-tuning:\n" + trimmedFineTuning)
            }
            guard !parts.isEmpty else { return nil }
            return """
            Write meeting notes for the transcript above. Output Markdown only and begin \
            directly with the notes: no preamble, no speaker list, and nothing that is not \
            in the transcript. Follow these instructions:

            \(parts.joined(separator: "\n\n"))
            """
        }
    }

    /// The setup in `preferences` and `store`; `nil` when TypeWhisper never set up notes.
    public static func setup(
        preferences: UserDefaults? = UserDefaults(suiteName: preferencesDomain),
        store: URL = workflowStoreURL
    ) -> Setup? {
        guard let preferences else { return nil }
        let folderPath = preferences.string(forKey: folderPathKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workflowID = preferences.string(forKey: workflowIDKey).flatMap(UUID.init(uuidString:))
        let chosen = workflowID.flatMap { Self.workflow(id: $0, in: store) }
        guard folderPath?.isEmpty == false || chosen != nil else { return nil }
        return Setup(folderPath: folderPath?.isEmpty == false ? folderPath : nil, workflow: chosen)
    }

    // MARK: - Workflow store

    /// The workflow with `id` from TypeWhisper's SwiftData store (SQLite, table
    /// `ZWORKFLOW`), `nil` when the store or the workflow cannot be read.
    static func workflow(id: UUID, in store: URL) -> Workflow? {
        guard FileManager.default.fileExists(atPath: store.path) else { return nil }
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(store.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT ZID, ZNAME, ZBEHAVIORDATA FROM ZWORKFLOW"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }

        let wanted = withUnsafeBytes(of: id.uuid) { Data($0) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard blob(statement, column: 0) == wanted else { continue }
            let name = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let behavior = blob(statement, column: 2).flatMap { try? JSONDecoder().decode(Behavior.self, from: $0) }
            let settings = behavior?.settings ?? [:]
            return Workflow(
                name: name,
                instruction: settings["instruction"] ?? settings["goal"] ?? settings["prompt"] ?? "",
                settings: settings.filter { !instructionKeys.contains($0.key) },
                fineTuning: behavior?.fineTuning ?? ""
            )
        }
        return nil
    }

    /// Settings that hold the instruction itself or only matter for dictation.
    private static let instructionKeys: Set<String> = [
        "instruction", "goal", "prompt", "targetLanguage", "target", "inputLanguage", "translationProcessor"
    ]

    private struct Behavior: Decodable {
        var settings: [String: String]?
        var fineTuning: String?
    }

    private static func blob(_ statement: OpaquePointer?, column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
