import Foundation
import Observation
import os

/// The user's corrections for dictation, stored as JSON in
/// `~/Library/Application Support/Pavarotti/dictionary.json`.
///
/// Cohere Transcribe takes no vocabulary hints, so the dictionary works after
/// recognition: it replaces what was heard with what the user wants written.
@MainActor @Observable
public final class PersonalDictionary {
    /// What learning a correction did to the dictionary.
    public enum LearnOutcome: Equatable, Sendable {
        case added(DictionaryEntry)
        /// A learned entry got the newer replacement.
        case updated(DictionaryEntry)
        /// The user undid a learned correction, so it is gone.
        case removed(DictionaryEntry)
        case unchanged
    }

    public enum EditError: Error, Equatable, LocalizedError {
        case emptyText
        case sameText

        public var errorDescription: String? {
            switch self {
            case .emptyText: "Enter what dictation hears and what it should write."
            case .sameText: "The correction must differ from what dictation hears."
            }
        }
    }

    public private(set) var entries: [DictionaryEntry] = []
    @ObservationIgnored private let fileURL: URL?

    private static let logger = Logger(subsystem: "de.foxagon.pavarotti", category: "Dictionary")

    /// `fileURL` nil keeps the dictionary in memory, for tests and previews.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        entries = Self.load(from: fileURL)
    }

    public static var standardFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Pavarotti/dictionary.json")
    }

    // MARK: - Using the dictionary

    /// Applies the enabled corrections to a transcription and counts their use.
    public func apply(to text: String) -> String {
        let result = DictionaryReplacer.apply(entries, to: text)
        guard !result.usedEntryIDs.isEmpty else { return text }
        for index in entries.indices where result.usedEntryIDs.contains(entries[index].id) {
            entries[index].usageCount += 1
        }
        save()
        return result.text
    }

    /// Takes over a correction the user made after pasting.
    @discardableResult
    public func learn(_ correction: DetectedCorrection) -> LearnOutcome {
        let originalKey = DictionaryEntry.key(correction.original)
        let replacementKey = DictionaryEntry.key(correction.replacement)
        // The user changed our replacement back: the learned entry was wrong.
        if let index = entries.firstIndex(where: {
            $0.matchKey == replacementKey && DictionaryEntry.key($0.replacement) == originalKey
        }) {
            guard entries[index].source == .learned else { return .unchanged }
            let removed = entries.remove(at: index)
            save()
            return .removed(removed)
        }
        // The user refined a learned replacement ("Cohen" → "Coher" → "Cohere"):
        // keep one entry from the original heard text to the newest spelling.
        if let index = entries.firstIndex(where: {
            $0.source == .learned && DictionaryEntry.key($0.replacement) == originalKey
        }) {
            entries[index].replacement = correction.replacement
            entries[index].isEnabled = true
            save()
            return .updated(entries[index])
        }
        if let index = entries.firstIndex(where: { $0.matchKey == originalKey }) {
            guard entries[index].source == .learned, entries[index].replacement != correction.replacement else {
                return .unchanged
            }
            entries[index].replacement = correction.replacement
            entries[index].isEnabled = true
            save()
            return .updated(entries[index])
        }
        let entry = DictionaryEntry(original: correction.original, replacement: correction.replacement, source: .learned)
        entries.append(entry)
        save()
        return .added(entry)
    }

    // MARK: - Editing

    /// Adds a correction by hand. An existing entry for the same text gets the new
    /// replacement and counts as the user's own from then on.
    @discardableResult
    public func add(original: String, replacement: String) throws -> DictionaryEntry {
        let heard = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !written.isEmpty else { throw EditError.emptyText }
        guard heard != written else { throw EditError.sameText }
        if let index = entries.firstIndex(where: { $0.matchKey == DictionaryEntry.key(heard) }) {
            entries[index].replacement = written
            entries[index].source = .manual
            entries[index].isEnabled = true
            save()
            return entries[index]
        }
        let entry = DictionaryEntry(original: heard, replacement: written)
        entries.append(entry)
        save()
        return entry
    }

    public func setEnabled(_ isEnabled: Bool, id: DictionaryEntry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isEnabled != isEnabled else {
            return
        }
        entries[index].isEnabled = isEnabled
        save()
    }

    public func remove(id: DictionaryEntry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        save()
    }

    /// Adds entries that are not in the dictionary yet and returns how many were new.
    @discardableResult
    public func merge(_ incoming: [DictionaryEntry]) -> Int {
        var known = Set(entries.map(\.matchKey))
        var added = 0
        for entry in incoming where !known.contains(entry.matchKey) {
            entries.append(entry)
            known.insert(entry.matchKey)
            added += 1
        }
        if added > 0 {
            save()
        }
        return added
    }

    // MARK: - Storage

    private struct StoredFile: Codable {
        var entries: [DictionaryEntry]
    }

    private static func load(from fileURL: URL?) -> [DictionaryEntry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try decoder.decode(StoredFile.self, from: data).entries
        } catch {
            // Keep the unreadable file for a look later instead of overwriting it.
            let backup = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            logger.error("Dictionary unreadable, moved aside: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(StoredFile(entries: entries))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Saving the dictionary failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
