import Foundation
import Observation
import os

/// One dictation as it was pasted.
public struct DictationHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let text: String

    public init(id: UUID = UUID(), date: Date, text: String) {
        self.id = id
        self.date = date
        self.text = text
    }

    /// One menu line: the time, the day too when it is not `now`'s, and the start of the
    /// text on a single line.
    public func menuTitle(now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var format = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute()
        if !calendar.isDate(date, inSameDayAs: now) {
            format = format.day().month(.abbreviated)
        }
        return "\(date.formatted(format)) \u{2014} \(Self.preview(of: text))"
    }

    /// Text longer than this is cut in the menu.
    static let previewLength = 60

    static func preview(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard line.count > previewLength else { return line }
        return line.prefix(previewLength).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

/// The last dictations, newest first, so text that did not arrive can be copied again.
/// Stored as JSON in `~/Library/Application Support/Pavarotti/dictation-history.json`.
@MainActor @Observable
public final class DictationHistory {
    /// How many dictations are kept.
    public static let limit = 20

    public private(set) var entries: [DictationHistoryEntry] = []
    private let fileURL: URL?

    private static let logger = Logger(subsystem: "de.foxagon.pavarotti", category: "DictationHistory")

    /// `fileURL` nil keeps the history in memory, for tests and previews.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        entries = Self.load(from: fileURL)
    }

    public static var standardFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Pavarotti/dictation-history.json")
    }

    /// Adds a dictation at the top and drops the oldest beyond ``limit``.
    public func record(_ text: String, at date: Date = .now) {
        entries.insert(DictationHistoryEntry(date: date, text: text), at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
        save()
    }

    public func clear() {
        entries = []
        save()
    }

    // MARK: - Storage

    private struct StoredFile: Codable {
        var entries: [DictationHistoryEntry]
    }

    private static func load(from fileURL: URL?) -> [DictationHistoryEntry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try decoder.decode(StoredFile.self, from: data).entries
        } catch {
            // Only a convenience: start over instead of keeping a broken file around.
            logger.error("Dictation history unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
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
            Self.logger.error("Saving the dictation history failed: \(error.localizedDescription, privacy: .public)")
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

public extension DictationController {
    /// The last dictations, for the menu bar.
    var history: DictationHistory {
        dependencies.history
    }
}
