import Foundation

/// Applies dictionary corrections to transcribed text.
///
/// Longer originals go first, so "Pava Rotti" is fixed before a shorter entry could
/// touch part of it. A match must stand on its own: "Rotti" does not change inside
/// "Pavarotti". Spaces inside a multi-word original match any run of whitespace.
public enum DictionaryReplacer {
    public struct Result: Equatable, Sendable {
        public let text: String
        /// Entries that changed the text, for usage counts.
        public let usedEntryIDs: Set<UUID>
    }

    public static func apply(_ entries: [DictionaryEntry], to text: String) -> Result {
        let active = entries
            .filter { $0.isEnabled && !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.original.count > $1.original.count }
        var current = text
        var used = Set<UUID>()
        for entry in active {
            guard let regex = expression(for: entry.original) else { continue }
            let range = NSRange(current.startIndex..., in: current)
            guard regex.firstMatch(in: current, range: range) != nil else { continue }
            let template = NSRegularExpression.escapedTemplate(for: entry.replacement)
            current = regex.stringByReplacingMatches(in: current, range: range, withTemplate: template)
            used.insert(entry.id)
        }
        return Result(text: current, usedEntryIDs: used)
    }

    /// Whole-word, case-insensitive pattern for `original`.
    static func expression(for original: String) -> NSRegularExpression? {
        let words = original.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        let pattern = "(?<![\\p{L}\\p{N}])" + words.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
