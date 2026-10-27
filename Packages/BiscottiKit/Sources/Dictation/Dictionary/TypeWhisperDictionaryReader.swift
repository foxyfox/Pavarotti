import Foundation
import SQLite3

/// Reads the corrections from TypeWhisper's dictionary (`dictionary.store`, a SwiftData
/// SQLite file) without opening TypeWhisper. Terms are counted but not taken over:
/// Cohere Transcribe cannot use vocabulary hints.
enum TypeWhisperDictionaryReader {
    struct Contents: Equatable {
        var corrections: [DictionaryEntry] = []
        var termCount = 0
    }

    enum ReadError: Error, Equatable, LocalizedError {
        case cannotOpen(String)
        case unknownLayout

        var errorDescription: String? {
            switch self {
            case let .cannotOpen(reason): "TypeWhisper's dictionary could not be opened (\(reason))."
            case .unknownLayout: "TypeWhisper's dictionary has a layout Pavarotti does not know."
            }
        }
    }

    /// The store of a TypeWhisper support folder.
    static func storeURL(in supportDirectory: URL) -> URL {
        supportDirectory.appending(path: "dictionary.store")
    }

    /// Reads a copy of the store, so a running TypeWhisper is not disturbed and changes
    /// still in its write-ahead log are included.
    static func read(storeAt storeURL: URL) throws -> Contents {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pavarotti-twdict-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: "dictionary.store")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database = handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
            sqlite3_close(handle)
            throw ReadError.cannotOpen(reason)
        }
        defer { sqlite3_close(database) }
        return try readEntries(from: database)
    }

    private static func readEntries(from database: OpaquePointer) throws -> Contents {
        // SwiftData keeps the entity in a Core Data table, ZDICTIONARYENTRY.
        let tables = try strings(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND upper(name) LIKE '%DICTIONARYENTRY'",
            in: database
        )
        guard let table = tables.first?.compactMap(\.self).first else { throw ReadError.unknownLayout }
        let columns = try Set(strings("PRAGMA table_info(\(table))", in: database).compactMap { $0.count > 1 ? $0[1] : nil })
        guard columns.contains("ZORIGINAL") else { throw ReadError.unknownLayout }
        func column(_ name: String) -> String {
            columns.contains(name) ? name : "NULL"
        }
        let query = "SELECT \(column("ZENTRYTYPE")), ZORIGINAL, \(column("ZREPLACEMENT")), \(column("ZISENABLED")) FROM \(table)"
        var contents = Contents()
        for row in try strings(query, in: database) {
            let original = (row[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = (row[2] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty else { continue }
            guard row[0] == "correction", !replacement.isEmpty else {
                contents.termCount += 1
                continue
            }
            let entry = DictionaryEntry(
                original: original,
                replacement: replacement,
                isEnabled: row[3] != "0",
                source: .imported
            )
            contents.corrections.append(entry)
        }
        return contents
    }

    /// Runs `query` and returns every row as text (`nil` for SQL NULL).
    private static func strings(_ query: String, in database: OpaquePointer) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            sqlite3_finalize(statement)
            throw ReadError.cannotOpen(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(prepared) }
        var rows: [[String?]] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            let count = sqlite3_column_count(prepared)
            rows.append((0 ..< count).map { index in
                sqlite3_column_text(prepared, index).map { String(cString: $0) }
            })
        }
        return rows
    }
}
