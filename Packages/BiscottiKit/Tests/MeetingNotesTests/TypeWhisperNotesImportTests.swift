import Foundation
import SQLite3
import Testing
@testable import MeetingNotes

@Suite("TypeWhisper meeting notes import")
struct TypeWhisperNotesImportTests {
    let workflowID = UUID()
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "TypeWhisperNotesImportTests.\(UUID().uuidString)", directoryHint: .isDirectory)

    private var storeURL: URL {
        directory.appending(path: "workflows.store", directoryHint: .notDirectory)
    }

    /// A workflow store shaped like TypeWhisper's SwiftData file, with `workflowID` and one
    /// other workflow.
    private func makeStore() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        try #require(sqlite3_open(storeURL.path, &database) == SQLITE_OK)
        try #require(sqlite3_exec(
            database, "CREATE TABLE ZWORKFLOW (Z_PK INTEGER PRIMARY KEY, ZID BLOB, ZNAME VARCHAR, ZBEHAVIORDATA BLOB)", nil, nil, nil
        ) == SQLITE_OK)
        let behavior = #"{"settings":{"instruction":"Fasse die Besprechung zusammen.","tone":"knapp","targetLanguage":"de","empty":" "},"fineTuning":"Nur Fakten."}"#
        try insert(id: UUID(), name: "Übersetzen", behavior: #"{"settings":{"instruction":"Übersetze."}}"#, into: database)
        try insert(id: workflowID, name: "Besprechungsnotizen", behavior: behavior, into: database)
    }

    private func insert(id: UUID, name: String, behavior: String, into database: OpaquePointer?) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_prepare_v2(database, "INSERT INTO ZWORKFLOW (ZID, ZNAME, ZBEHAVIORDATA) VALUES (?, ?, ?)", -1, &statement, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let idData = withUnsafeBytes(of: id.uuid) { Data($0) }
        let behaviorData = Data(behavior.utf8)
        _ = idData.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
        _ = sqlite3_bind_text(statement, 2, name, -1, transient)
        _ = behaviorData.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient) }
        try #require(sqlite3_step(statement) == SQLITE_DONE)
    }

    private func preferences(folder: String?, workflow: UUID?) throws -> (UserDefaults, String) {
        let suite = "TypeWhisperNotesImportTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(folder, forKey: TypeWhisperNotesImport.folderPathKey)
        defaults.set(workflow?.uuidString, forKey: TypeWhisperNotesImport.workflowIDKey)
        return (defaults, suite)
    }

    @Test("The folder and the notes workflow are taken over")
    func takesOverSetup() throws {
        try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try preferences(folder: " /Users/a/Notizen ", workflow: workflowID)
        defer { defaults.removePersistentDomain(forName: suite) }

        let setup = try #require(TypeWhisperNotesImport.setup(preferences: defaults, store: storeURL))

        #expect(setup.folderPath == "/Users/a/Notizen")
        let workflow = try #require(setup.workflow)
        #expect(workflow.name == "Besprechungsnotizen")
        #expect(workflow.instruction == "Fasse die Besprechung zusammen.")
        #expect(workflow.settings == ["tone": "knapp", "empty": " "])
        #expect(workflow.fineTuning == "Nur Fakten.")
        let prompt = try #require(workflow.summaryPrompt)
        #expect(prompt.hasPrefix("Write meeting notes for the transcript above. Output Markdown only"))
        #expect(prompt.hasSuffix("""
        Follow these instructions:

        Fasse die Besprechung zusammen.

        Additional settings:
        - tone: knapp

        Fine-tuning:
        Nur Fakten.
        """))
    }

    @Test("Without a workflow store only the folder is taken over")
    func folderOnly() throws {
        let (defaults, suite) = try preferences(folder: "/Users/a/Notizen", workflow: workflowID)
        defer { defaults.removePersistentDomain(forName: suite) }

        let setup = TypeWhisperNotesImport.setup(preferences: defaults, store: storeURL)
        #expect(setup == TypeWhisperNotesImport.Setup(folderPath: "/Users/a/Notizen", workflow: nil))
    }

    @Test("Nothing set up in TypeWhisper means nothing to take over")
    func nothingSetUp() throws {
        try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = try preferences(folder: " ", workflow: UUID())
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(TypeWhisperNotesImport.setup(preferences: defaults, store: storeURL) == nil)
    }

    @Test("A workflow without instructions gives no prompt")
    func emptyWorkflow() {
        let workflow = TypeWhisperNotesImport.Workflow(name: "Leer", instruction: " ", settings: ["a": ""], fineTuning: "")
        #expect(workflow.summaryPrompt == nil)
    }
}
