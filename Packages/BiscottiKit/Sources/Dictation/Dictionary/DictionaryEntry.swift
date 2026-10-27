import Foundation

/// One correction in the personal dictionary: when dictation hears `original`, it writes
/// `replacement` instead. Matching ignores case and only hits whole words.
public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    /// Where an entry came from, so learned ones can be told apart and reviewed.
    public enum Source: String, Codable, Sendable {
        case manual
        /// Picked up from a correction the user made after pasting.
        case learned
        /// Taken over from TypeWhisper.
        case imported
    }

    public let id: UUID
    public var original: String
    public var replacement: String
    public var isEnabled: Bool
    public var source: Source
    /// How many dictations this correction changed.
    public var usageCount: Int
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        original: String,
        replacement: String,
        isEnabled: Bool = true,
        source: Source = .manual,
        usageCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.original = original
        self.replacement = replacement
        self.isEnabled = isEnabled
        self.source = source
        self.usageCount = usageCount
        self.createdAt = createdAt
    }

    /// The text the entry matches, for duplicate checks.
    var matchKey: String {
        DictionaryEntry.key(original)
    }

    static func key(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

/// A correction found in what the user changed after pasting.
public struct DetectedCorrection: Equatable, Sendable {
    public let original: String
    public let replacement: String

    public init(original: String, replacement: String) {
        self.original = original
        self.replacement = replacement
    }
}
