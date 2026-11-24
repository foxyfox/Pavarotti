import Foundation

/// Checks whether the text of an automatic transcription is in the language that was
/// detected, by counting words only German or only English uses.
///
/// Silero sometimes hears English in German speech, for example when a dictation is
/// short or holds English terms. Cohere then writes in the wrong language: part of the
/// German stays German, the rest comes out translated. Real English speech written as
/// English holds almost no German words, so many of them show the detection was wrong.
/// German is preferred: switching from German to English needs much clearer evidence.
enum TextLanguageCheck {
    /// The language to redo an automatic transcription in, or `nil` when `text` fits
    /// `language`. Only German and English are checked.
    static func correctedLanguage(for text: String, transcribedAs language: String) -> String? {
        let words = words(in: text)
        guard words.count >= minimumWords else { return nil }
        let german = words.count(where: isGerman)
        let english = words.count(where: englishWords.contains)
        let total = Double(words.count)
        switch language {
        case "en":
            // German speech written as English keeps German words; English speech does not.
            let isGerman = german >= 3 && Double(german) / total >= 0.08
            return isGerman ? "de" : nil
        case "de":
            // English speech written as German: mostly English words, hardly any German.
            let isEnglish = english >= 4 && Double(english) / total >= 0.25 && english >= german * 3
            return isEnglish ? "en" : nil
        default:
            return nil
        }
    }

    static let minimumWords = 4

    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'’")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }
            .filter { !$0.isEmpty }
    }

    private static func isGerman(_ word: String) -> Bool {
        germanWords.contains(word) || word.contains(where: "äöüß".contains)
    }

    /// Common German words that are not English words too (no "also", "was", "will",
    /// "man", "die", "so", "in", "am", "an", "hat").
    static let germanWords: Set<String> = [
        "und", "ich", "nicht", "aber", "dass", "das", "ist", "ein", "eine", "einen", "einem", "einer",
        "der", "den", "dem", "des", "wir", "sie", "mit", "auf", "für", "von", "zu", "zum", "zur",
        "auch", "noch", "nur", "wenn", "dann", "schon", "oder", "sich", "mich", "mir", "dir", "du",
        "es", "bei", "nach", "wie", "mal", "jetzt", "kann", "können", "muss", "müssen", "haben",
        "habe", "hast", "sind", "bin", "wird", "werden", "wurde", "hier", "eigentlich", "gibt",
        "kein", "keine", "sehr", "weil", "doch", "ja", "nein", "nichts", "etwas", "diese", "dieser",
        "dieses", "diesen", "immer", "wieder", "aus", "über", "unter", "bitte", "danke",
        "ganz", "würde", "wäre", "soll", "sollte", "machen", "macht", "geht", "denn", "eben", "halt"
    ]

    /// Common English words that are not German words too (no "was", "will", "man",
    /// "so", "in", "also", "hat", "bin", "die", "an", "am").
    static let englishWords: Set<String> = [
        "the", "and", "is", "are", "i", "you", "it", "that", "this", "with", "of", "to", "for",
        "have", "has", "were", "would", "should", "could", "can't", "don't", "it's", "i'm", "what",
        "which", "my", "your", "we", "they", "not", "but", "be", "been", "just", "there", "here",
        "if", "when", "then", "or", "from", "at", "on", "about", "because", "some", "any", "do",
        "does", "did", "how", "why", "where", "who", "our", "their", "them", "he", "she", "his",
        "very", "really", "think", "know", "want", "need", "like", "get", "make"
    ]
}
