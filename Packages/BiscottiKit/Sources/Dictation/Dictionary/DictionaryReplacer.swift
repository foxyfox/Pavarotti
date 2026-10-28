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
        apply(Rules(entries), to: text)
    }

    /// One enabled entry, compiled.
    struct Rule {
        let id: UUID
        let regex: NSRegularExpression
        let template: String
    }

    /// The enabled entries compiled once, longest original first, for applying them to
    /// many texts, such as every sentence and word of a meeting.
    public struct Rules {
        let rules: [Rule]

        public var isEmpty: Bool {
            rules.isEmpty
        }

        public init(_ entries: [DictionaryEntry]) {
            rules = entries
                .filter { $0.isEnabled && !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.original.count > $1.original.count }
                .compactMap { entry in
                    DictionaryReplacer.expression(for: entry.original).map {
                        Rule(id: entry.id, regex: $0, template: NSRegularExpression.escapedTemplate(for: entry.replacement))
                    }
                }
        }
    }

    public static func apply(_ rules: Rules, to text: String) -> Result {
        var current = text
        var used = Set<UUID>()
        for rule in rules.rules {
            let range = NSRange(current.startIndex..., in: current)
            guard rule.regex.firstMatch(in: current, range: range) != nil else { continue }
            current = rule.regex.stringByReplacingMatches(in: current, range: range, withTemplate: rule.template)
            used.insert(rule.id)
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
