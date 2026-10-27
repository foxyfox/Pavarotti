import Foundation

/// Finds the word the user fixed in pasted dictation text.
///
/// It compares the text field right after pasting with the field later on. Only a
/// small, local fix inside the pasted text counts: one to three words replaced by one
/// to three similar-looking words, such as "Cohen" → "Cohere" or "Pava Rotti" →
/// "Pavarotti". Rewrites, grammar tweaks, case changes and edits outside the pasted
/// text are ignored, so the dictionary only learns real recognition errors.
public enum CorrectionDetector {
    /// Most words on either side of a correction.
    static let maximumWords = 3
    /// Longest original that is still learned.
    static let maximumLength = 40
    /// How alike original and replacement must look (0 to 1).
    static let minimumSimilarity = 0.5

    /// The correction between `before` (the field right after pasting `inserted`) and
    /// `after` (the field now), or `nil` when the change is not a clear word fix.
    public static func correction(inserted: String, before: String, after: String) -> DetectedCorrection? {
        let old = Array(before)
        let new = Array(after)
        let pasted = Array(inserted)
        guard old != new, !pasted.isEmpty, let change = ChangedSpan(old: old, new: new) else { return nil }
        let oldWords = change.expandedToWords(in: old, range: change.oldRange)
        let newWords = change.expandedToWords(in: new, range: change.newRange)
        guard isInsidePastedText(oldWords, pasted: pasted, in: old) else { return nil }
        let original = trimmed(String(old[oldWords]))
        let replacement = trimmed(String(new[newWords]))
        guard isWordFix(original: original, replacement: replacement) else { return nil }
        return DetectedCorrection(original: original, replacement: replacement)
    }

    /// Whether the change looks like a fixed recognition error.
    static func isWordFix(original: String, replacement: String) -> Bool {
        let originalWords = original.split(whereSeparator: \.isWhitespace)
        let replacementWords = replacement.split(whereSeparator: \.isWhitespace)
        guard (1 ... maximumWords).contains(originalWords.count),
              (1 ... maximumWords).contains(replacementWords.count),
              original.count <= maximumLength,
              original.contains(where: \.isLetter),
              replacement.contains(where: \.isLetter)
        else {
            return false
        }
        let oldKey = original.lowercased()
        let newKey = replacement.lowercased()
        // A change of case only, such as at the start of a sentence.
        guard oldKey != newKey else { return false }
        // An ending added or removed, such as "ein" → "eine": grammar, not recognition.
        if oldKey.hasPrefix(newKey) || newKey.hasPrefix(oldKey), abs(oldKey.count - newKey.count) <= 3 {
            return false
        }
        return similarity(oldKey, newKey) >= minimumSimilarity
    }

    /// 1 minus the edit distance relative to the longer text, ignoring spaces, so a word
    /// split in two still counts as the same word.
    static func similarity(_ first: String, _ second: String) -> Double {
        let lhs = Array(first.filter { !$0.isWhitespace })
        let rhs = Array(second.filter { !$0.isWhitespace })
        let longest = max(lhs.count, rhs.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(editDistance(lhs, rhs)) / Double(longest)
    }

    static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0 ... rhs.count)
        for (row, left) in lhs.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: rhs.count)
            for (column, right) in rhs.enumerated() {
                let substitution = previous[column] + (left == right ? 0 : 1)
                current[column + 1] = min(substitution, previous[column + 1] + 1, current[column] + 1)
            }
            previous = current
        }
        return previous[rhs.count]
    }

    /// Whether `range` of `text` lies within one occurrence of the pasted text.
    private static func isInsidePastedText(_ range: Range<Int>, pasted: [Character], in text: [Character]) -> Bool {
        guard pasted.count <= text.count, range.count <= pasted.count else { return false }
        // Only occurrences that can cover the range need a look.
        let first = max(0, range.upperBound - pasted.count)
        let last = min(range.lowerBound, text.count - pasted.count)
        guard first <= last else { return false }
        return (first ... last).contains { start in
            text[start ..< start + pasted.count].elementsEqual(pasted)
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

/// The part of a text that changed: everything between the common start and end.
struct ChangedSpan {
    let oldRange: Range<Int>
    let newRange: Range<Int>

    init?(old: [Character], new: [Character]) {
        guard old != new else { return nil }
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
        {
            suffix += 1
        }
        oldRange = prefix ..< old.count - suffix
        newRange = prefix ..< new.count - suffix
    }

    /// `range` widened to whole words, so "Coh|en|" becomes "Cohen".
    func expandedToWords(in text: [Character], range: Range<Int>) -> Range<Int> {
        var lower = range.lowerBound
        while lower > 0, !text[lower - 1].isWhitespace {
            lower -= 1
        }
        var upper = range.upperBound
        while upper < text.count, !text[upper].isWhitespace {
            upper += 1
        }
        return lower ..< upper
    }
}
