import Foundation

/// Pavarotti: splits recognized words into sentences, ported from Andreas's TypeWhisper fork.
///
/// A sentence ends after a word ending in `.`, `?`, `!` or `…` (closing quotes or brackets
/// may follow the mark). Rules against false ends, for Cohere's German and English output,
/// which capitalizes sentence starts:
/// - `.` or `…` before a word that starts with a lowercase letter does not end a sentence
///   ("z.B. wenn", "der 28. ist", "und … ja").
/// - Common abbreviations ("bzw.", "ca. 10", "Dr.", "Nr."), single letters ("z.", "B.") and
///   dotted letter groups ("z.B.", "d.h.", "U.S.") never end a sentence.
/// - A day before a German month name ("am 3. Oktober") does not end a sentence.
/// - A number after an article or preposition is a spoken ordinal ("im 3. Quartal",
///   "zum 2. Mal") and does not end a sentence; "Es waren 15." does.
///
/// Anything else ends the sentence: two halves of one sentence harm the speaker matching
/// less than one sentence spanning two speakers.
enum SentenceSplitter {
    /// The words in sentences, in order. Words without text are dropped; words after the
    /// last sentence mark form a final sentence.
    static func sentences(of words: [ProvidedTranscript.Word]) -> [[ProvidedTranscript.Word]] {
        let words = words.compactMap { word -> ProvidedTranscript.Word? in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ProvidedTranscript.Word(text: text, start: word.start, end: word.end)
        }
        var sentences: [[ProvidedTranscript.Word]] = []
        var current: [ProvidedTranscript.Word] = []
        for (index, word) in words.enumerated() {
            current.append(word)
            let previous = index > 0 ? words[index - 1].text : nil
            let next = words.indices.contains(index + 1) ? words[index + 1].text : nil
            if endsSentence(word.text, after: previous, before: next) {
                sentences.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            sentences.append(current)
        }
        return sentences
    }

    static func endsSentence(_ word: String, after previousWord: String? = nil, before nextWord: String?) -> Bool {
        var mark = Substring(word)
        while let last = mark.last, closingCharacters.contains(last) {
            mark = mark.dropLast()
        }
        guard let last = mark.last, sentenceMarks.contains(last) else { return false }
        guard last == "." || last == "…" else { return true }

        if let nextWord,
           let first = nextWord.first(where: { !openingCharacters.contains($0) }),
           first.isLowercase
        {
            return false
        }
        guard last == "." else { return true }
        return !isAbbreviation(mark)
            && !isDayBeforeMonth(mark, nextWord: nextWord)
            && !isOrdinalAfterDeterminer(mark, previousWord: previousWord)
    }

    private static let sentenceMarks: Set<Character> = [".", "?", "!", "…"]
    private static let closingCharacters: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "»", "«", "›", "‹", ")", "]"]
    private static let openingCharacters: Set<Character> = ["\"", "'", "„", "“", "‚", "‘", "»", "«", "›", "‹", "(", "["]

    /// Lowercased, with the trailing dot. Abbreviations that often end a sentence ("usw.",
    /// "etc.") are left out on purpose.
    private static let abbreviations: Set<String> = [
        "bzw.", "ca.", "dr.", "evtl.", "ggf.", "inkl.", "zzgl.", "vgl.", "bspw.", "nr.",
        "prof.", "hr.", "fr.", "st.", "abs.", "tel.", "mr.", "mrs.", "ms.", "vs."
    ]

    private static let germanMonths: Set<String> = [
        "januar", "jänner", "februar", "märz", "april", "mai", "juni",
        "juli", "august", "september", "oktober", "november", "dezember"
    ]

    /// `word` ends with ".".
    private static func isAbbreviation(_ word: Substring) -> Bool {
        if abbreviations.contains(word.lowercased()) { return true }
        // "z.", "B.", "z.B.", "d.h.", "U.S.": every dot-separated part is a single letter.
        let parts = word.dropLast().split(separator: ".", omittingEmptySubsequences: false)
        return parts.allSatisfy { $0.count == 1 && $0.first?.isLetter == true }
    }

    /// `word` ends with ".".
    private static func isDayBeforeMonth(_ word: Substring, nextWord: String?) -> Bool {
        let day = word.dropLast()
        guard (1 ... 2).contains(day.count), day.allSatisfy(\.isASCII), day.allSatisfy(\.isNumber),
              let nextWord
        else {
            return false
        }
        let month = nextWord.lowercased().filter(\.isLetter)
        return germanMonths.contains(month)
    }

    /// Articles and prepositions after which "<number>." is a spoken ordinal
    /// ("im 3. Quartal", "zum 2. Mal"), lowercased.
    private static let ordinalDeterminers: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "im", "am", "zum", "zur", "vom", "beim",
        "ab", "bis", "seit", "ins", "ans", "the"
    ]
    private static let ordinalDeterminerPrefixes = ["ein", "jede", "dies"]

    /// `word` ends with ".".
    private static func isOrdinalAfterDeterminer(_ word: Substring, previousWord: String?) -> Bool {
        let number = word.dropLast()
        guard (1 ... 3).contains(number.count), number.allSatisfy(\.isASCII), number.allSatisfy(\.isNumber),
              let previousWord
        else {
            return false
        }
        let determiner = previousWord.lowercased().filter(\.isLetter)
        return ordinalDeterminers.contains(determiner)
            || ordinalDeterminerPrefixes.contains { determiner.hasPrefix($0) && determiner.count <= $0.count + 2 }
    }
}
