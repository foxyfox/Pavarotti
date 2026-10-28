import Foundation
import SQLite3
import Testing
@testable import Dictation

@Suite("TypeWhisper dictionary")
@MainActor
struct TypeWhisperDictionaryTests {
    @Test("corrections are read, terms are only counted")
    func readsCorrections() throws {
        try withSupportFolder { folder in
            try makeStore(in: folder, rows: [
                StoreRow("correction", "Cohen", "Cohere"),
                StoreRow("correction", "Pava Rotti", " Pavarotti ", enabled: false),
                StoreRow("term", "Kubernetes"),
                StoreRow("correction", "leer", ""),
                StoreRow("correction", "  ", "nichts")
            ])
            let contents = try TypeWhisperDictionaryReader.read(storeAt: TypeWhisperDictionaryReader.storeURL(in: folder))

            #expect(contents.corrections.map(\.original) == ["Cohen", "Pava Rotti"])
            #expect(contents.corrections.map(\.replacement) == ["Cohere", "Pavarotti"])
            #expect(contents.corrections.map(\.isEnabled) == [true, false])
            #expect(contents.corrections.allSatisfy { $0.source == .imported })
            #expect(contents.termCount == 2)
        }
    }

    @Test("learned corrections must look like recognition errors, manual ones always count")
    func learnedCorrections() throws {
        try withSupportFolder { folder in
            try makeStore(in: folder, rows: [
                StoreRow("correction", "Gohe-Modell", "Cohere-Modell", source: "autoLearned"),
                StoreRow("correction", "unser", "unseres", source: "autoLearned"),
                StoreRow("correction", "Bilder", "designs", source: "autoLearned"),
                StoreRow("correction", "Clot", "Claude")
            ])
            let dictionary = PersonalDictionary(fileURL: nil)

            let summary = TypeWhisperImport.importDictionary(into: dictionary, supportDirectory: folder)

            #expect(dictionary.entries.map(\.original) == ["Gohe-Modell", "Clot"])
            #expect(summary == "Dictionary: 2 of 2 corrections added. "
                + "Learned rewrites left out: unser \u{2192} unseres, Bilder \u{2192} designs.")
        }
    }

    @Test("TypeWhisper is imported once: everything on a fresh install, else the dictionary")
    func launchImport() {
        typealias Plan = TypeWhisperImport.LaunchImport
        #expect(Plan(checkedBefore: false, available: true, settingsSaved: false) == .everything)
        #expect(Plan(checkedBefore: false, available: true, settingsSaved: true) == .dictionary)
        #expect(Plan(checkedBefore: true, available: true, settingsSaved: false) == .nothing)
        #expect(Plan(checkedBefore: false, available: false, settingsSaved: false) == .nothing)
    }

    @Test("a store without the dictionary table is reported")
    func unknownLayout() throws {
        try withSupportFolder { folder in
            try execute(["CREATE TABLE ZSOMETHING (Z_PK INTEGER PRIMARY KEY)"], in: folder)
            #expect(throws: TypeWhisperDictionaryReader.ReadError.unknownLayout) {
                try TypeWhisperDictionaryReader.read(storeAt: TypeWhisperDictionaryReader.storeURL(in: folder))
            }
        }
    }

    @Test("importing merges new corrections and explains what was left out")
    func importSummary() throws {
        try withSupportFolder { folder in
            try makeStore(in: folder, rows: [
                StoreRow("correction", "Cohen", "Cohere"),
                StoreRow("correction", "Pava Rotti", "Pavarotti"),
                StoreRow("term", "Kubernetes")
            ])
            let dictionary = PersonalDictionary(fileURL: nil)
            try dictionary.add(original: "cohen", replacement: "Cohere Labs")

            let summary = TypeWhisperImport.importDictionary(into: dictionary, supportDirectory: folder)

            #expect(summary == "Dictionary: 1 of 2 corrections added. 1 term left out, Cohere cannot use it.")
            #expect(dictionary.entries.map(\.replacement) == ["Cohere Labs", "Pavarotti"])
        }
    }

    @Test("no store means nothing to say, a broken one is skipped")
    func missingAndBrokenStores() throws {
        try withSupportFolder { folder in
            let dictionary = PersonalDictionary(fileURL: nil)
            #expect(TypeWhisperImport.importDictionary(into: dictionary, supportDirectory: folder) == nil)

            try Data("not a database".utf8).write(to: TypeWhisperDictionaryReader.storeURL(in: folder))
            let summary = try #require(TypeWhisperImport.importDictionary(into: dictionary, supportDirectory: folder))
            #expect(summary.hasPrefix("Dictionary skipped:"))
            #expect(dictionary.entries.isEmpty)
        }
    }
}

// MARK: - Fixture

/// One row of TypeWhisper's dictionary.
private struct StoreRow {
    let type: String
    let original: String
    let replacement: String?
    let enabled: Bool
    let source: String

    init(_ type: String, _ original: String, _ replacement: String? = nil, enabled: Bool = true, source: String = "manual") {
        self.type = type
        self.original = original
        self.replacement = replacement
        self.enabled = enabled
        self.source = source
    }
}

private func withSupportFolder(_ body: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "pavarotti-twdict-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(folder)
}

/// Writes a `dictionary.store` laid out like SwiftData's Core Data table.
private func makeStore(in folder: URL, rows: [StoreRow]) throws {
    let create = """
    CREATE TABLE ZDICTIONARYENTRY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, \
    ZCASESENSITIVE INTEGER, ZISENABLED INTEGER, ZUSAGECOUNT INTEGER, ZENTRYTYPE VARCHAR, \
    ZORIGINAL VARCHAR, ZREPLACEMENT VARCHAR, ZSOURCERAWVALUE VARCHAR)
    """
    let inserts = rows.map { row in
        let replacement = row.replacement.map { "'\($0)'" } ?? "NULL"
        return "INSERT INTO ZDICTIONARYENTRY (Z_ENT, Z_OPT, ZCASESENSITIVE, ZISENABLED, ZUSAGECOUNT, ZENTRYTYPE, "
            + "ZORIGINAL, ZREPLACEMENT, ZSOURCERAWVALUE) VALUES (1, 1, 0, \(row.enabled ? 1 : 0), 0, '\(row.type)', "
            + "'\(row.original)', \(replacement), '\(row.source)')"
    }
    try execute([create] + inserts, in: folder)
}

private struct SQLiteFailure: Error {
    let message: String
}

private func execute(_ statements: [String], in folder: URL) throws {
    var handle: OpaquePointer?
    let path = TypeWhisperDictionaryReader.storeURL(in: folder).path
    guard sqlite3_open(path, &handle) == SQLITE_OK, let database = handle else {
        sqlite3_close(handle)
        throw SQLiteFailure(message: "open failed")
    }
    defer { sqlite3_close(database) }
    for statement in statements {
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteFailure(message: String(cString: sqlite3_errmsg(database)))
        }
    }
}
