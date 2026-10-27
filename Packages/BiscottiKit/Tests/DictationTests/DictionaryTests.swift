import Foundation
import Testing
@testable import Dictation

@Suite("DictionaryReplacer")
struct DictionaryReplacerTests {
    private func entry(_ original: String, _ replacement: String, enabled: Bool = true) -> DictionaryEntry {
        DictionaryEntry(original: original, replacement: replacement, isEnabled: enabled)
    }

    @Test("replaces whole words regardless of case")
    func wholeWordsIgnoringCase() {
        let cohen = entry("Cohen", "Cohere")
        let result = DictionaryReplacer.apply([cohen], to: "cohen transcribe, COHEN! Cohenstraße")
        #expect(result.text == "Cohere transcribe, Cohere! Cohenstraße")
        #expect(result.usedEntryIDs == [cohen.id])
    }

    @Test("multi-word originals match any whitespace")
    func multiWordOriginals() {
        let result = DictionaryReplacer.apply([entry("Pava Rotti", "Pavarotti")], to: "Ich nutze Pava  Rotti\nseit heute")
        #expect(result.text == "Ich nutze Pavarotti\nseit heute")
    }

    @Test("longer originals go first")
    func longestFirst() {
        let entries = [entry("Rotti", "Brot"), entry("Pava Rotti", "Pavarotti")]
        #expect(DictionaryReplacer.apply(entries, to: "Pava Rotti und Rotti").text == "Pavarotti und Brot")
    }

    @Test("umlauts count as letters at word edges")
    func umlautBoundaries() {
        let result = DictionaryReplacer.apply([entry("Mul", "Müll")], to: "Mul Müller Mulü")
        #expect(result.text == "Müll Müller Mulü")
    }

    @Test("special characters are matched literally")
    func literalMatching() {
        let entries = [entry("C plus plus", "C++"), entry("a.b", "$1 \\0")]
        let result = DictionaryReplacer.apply(entries, to: "C plus plus und a.b und axb")
        #expect(result.text == "C++ und $1 \\0 und axb")
    }

    @Test("disabled entries and misses change nothing")
    func disabledAndMisses() {
        let entries = [entry("Cohen", "Cohere", enabled: false), entry("Zebra", "Pferd")]
        let result = DictionaryReplacer.apply(entries, to: "Cohen sagt hallo")
        #expect(result.text == "Cohen sagt hallo")
        #expect(result.usedEntryIDs.isEmpty)
    }
}

@Suite("CorrectionDetector")
struct CorrectionDetectorTests {
    private func detect(_ inserted: String, before: String, after: String) -> DetectedCorrection? {
        CorrectionDetector.correction(inserted: inserted, before: before, after: after)
    }

    @Test("a fixed word inside the pasted text")
    func fixedWord() {
        let inserted = "Wir testen Cohen Transcribe heute"
        let found = detect(inserted, before: "Hallo! \(inserted)", after: "Hallo! Wir testen Cohere Transcribe heute")
        #expect(found == DetectedCorrection(original: "Cohen", replacement: "Cohere"))
    }

    @Test("punctuation around the word is not part of the correction")
    func punctuationStripped() {
        let found = detect("Danke, Cohen.", before: "Danke, Cohen.", after: "Danke, Cohere.")
        #expect(found == DetectedCorrection(original: "Cohen", replacement: "Cohere"))
    }

    @Test("two words merged into one")
    func mergedWords() {
        let found = detect("Ich mag Pava Rotti sehr", before: "Ich mag Pava Rotti sehr", after: "Ich mag Pavarotti sehr")
        #expect(found == DetectedCorrection(original: "Pava Rotti", replacement: "Pavarotti"))
    }

    @Test("the pasted text can appear twice; the edited copy counts")
    func repeatedPaste() {
        let found = detect("Cohen ist gut", before: "Cohen ist gut. Cohen ist gut", after: "Cohen ist gut. Cohere ist gut")
        #expect(found == DetectedCorrection(original: "Cohen", replacement: "Cohere"))
    }

    @Test("changes outside the pasted text are ignored")
    func outsideChanges() {
        #expect(detect("Cohen ist gut", before: "Hallo Welt Cohen ist gut", after: "Hallo Wald Cohen ist gut") == nil)
        #expect(detect("Cohen ist gut", before: "Cohen ist gut", after: "Cohere ist gut und mehr") == nil)
    }

    @Test("case changes, endings and rewrites are not learned")
    func notRecognitionErrors() {
        #expect(detect("das ist gut", before: "das ist gut", after: "Das ist gut") == nil)
        #expect(detect("ein Haus", before: "ein Haus", after: "eine Haus") == nil)
        #expect(detect("das ist gut", before: "das ist gut", after: "das ist schlecht") == nil)
        #expect(detect("ich sage gut", before: "ich sage gut", after: "ich sage sehr gut") == nil)
    }

    @Test("long rewrites and cleared fields are not learned")
    func largeChanges() {
        let inserted = "eins zwei drei vier fünf"
        #expect(detect(inserted, before: inserted, after: "one two three four five") == nil)
        #expect(detect(inserted, before: inserted, after: "") == nil)
        #expect(detect(inserted, before: inserted, after: inserted) == nil)
    }

    @Test("similarity ignores spaces and compares letters")
    func similarity() {
        #expect(CorrectionDetector.similarity("pava rotti", "pavarotti") == 1)
        #expect(CorrectionDetector.similarity("cohen", "cohere") > 0.6)
        #expect(CorrectionDetector.similarity("gut", "schlecht") < 0.3)
        #expect(CorrectionDetector.editDistance(Array("kitten"), Array("sitting")) == 3)
    }
}

@Suite("PersonalDictionary")
@MainActor
struct PersonalDictionaryTests {
    private let cohen = DetectedCorrection(original: "Cohen", replacement: "Cohere")

    @Test("learning adds, then ignores the same correction")
    func learnAddsOnce() {
        let dictionary = PersonalDictionary(fileURL: nil)
        guard case let .added(entry) = dictionary.learn(cohen) else {
            Issue.record("Expected a new entry")
            return
        }
        #expect(entry.source == .learned)
        #expect(dictionary.learn(cohen) == .unchanged)
        #expect(dictionary.entries.count == 1)
    }

    @Test("undoing a learned replacement removes it")
    func revertRemoves() {
        let dictionary = PersonalDictionary(fileURL: nil)
        dictionary.learn(cohen)
        let outcome = dictionary.learn(DetectedCorrection(original: "Cohere", replacement: "Cohen"))
        guard case .removed = outcome else {
            Issue.record("Expected the entry to be removed, got \(outcome)")
            return
        }
        #expect(dictionary.entries.isEmpty)
    }

    @Test("refining a learned replacement keeps one entry")
    func refineUpdates() {
        let dictionary = PersonalDictionary(fileURL: nil)
        dictionary.learn(DetectedCorrection(original: "Cohen", replacement: "Coher"))
        dictionary.learn(DetectedCorrection(original: "Coher", replacement: "Cohere"))
        #expect(dictionary.entries.map(\.original) == ["Cohen"])
        #expect(dictionary.entries.map(\.replacement) == ["Cohere"])
    }

    @Test("learning never overrides an entry the user added")
    func manualEntriesWin() throws {
        let dictionary = PersonalDictionary(fileURL: nil)
        try dictionary.add(original: "Cohen", replacement: "Cohere Labs")
        #expect(dictionary.learn(cohen) == .unchanged)
        #expect(dictionary.learn(DetectedCorrection(original: "Cohere Labs", replacement: "Cohen")) == .unchanged)
        #expect(dictionary.entries.map(\.replacement) == ["Cohere Labs"])
    }

    @Test("adding by hand validates and replaces an existing entry")
    func addByHand() throws {
        let dictionary = PersonalDictionary(fileURL: nil)
        #expect(throws: PersonalDictionary.EditError.emptyText) {
            try dictionary.add(original: " ", replacement: "x")
        }
        #expect(throws: PersonalDictionary.EditError.sameText) {
            try dictionary.add(original: "Cohere", replacement: "Cohere")
        }
        dictionary.learn(cohen)
        let entry = try dictionary.add(original: "cohen", replacement: "Cohere AI")
        #expect(entry.source == .manual)
        #expect(dictionary.entries.count == 1)
    }

    @Test("applying counts uses; disabling and removing work")
    func applyAndEdit() throws {
        let dictionary = PersonalDictionary(fileURL: nil)
        let entry = try dictionary.add(original: "Cohen", replacement: "Cohere")
        #expect(dictionary.apply(to: "Cohen hier") == "Cohere hier")
        #expect(dictionary.entries.first?.usageCount == 1)
        dictionary.setEnabled(false, id: entry.id)
        #expect(dictionary.apply(to: "Cohen hier") == "Cohen hier")
        dictionary.remove(id: entry.id)
        #expect(dictionary.entries.isEmpty)
    }

    @Test("merging skips texts that are already there")
    func mergeSkipsDuplicates() throws {
        let dictionary = PersonalDictionary(fileURL: nil)
        try dictionary.add(original: "Cohen", replacement: "Cohere")
        let incoming = [
            DictionaryEntry(original: "cohen", replacement: "Other", source: .imported),
            DictionaryEntry(original: "Kuber Netes", replacement: "Kubernetes", source: .imported),
            DictionaryEntry(original: "kuber  netes", replacement: "K8s", source: .imported)
        ]
        #expect(dictionary.merge(incoming) == 1)
        #expect(dictionary.entries.map(\.replacement) == ["Cohere", "Kubernetes"])
    }

    @Test("entries survive a restart, an unreadable file is moved aside")
    func persistence() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pavarotti-dictionary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "dictionary.json")

        let first = PersonalDictionary(fileURL: file)
        first.learn(cohen)
        try first.add(original: "Pava Rotti", replacement: "Pavarotti")
        // Dates are stored to the second, so compare everything else.
        let reloaded = PersonalDictionary(fileURL: file)
        #expect(reloaded.entries.map(\.id) == first.entries.map(\.id))
        #expect(reloaded.entries.map(\.replacement) == ["Cohere", "Pavarotti"])
        #expect(reloaded.entries.map(\.source) == [.learned, .manual])

        try Data("not json".utf8).write(to: file)
        #expect(PersonalDictionary(fileURL: file).entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("unreadable").path))
    }
}
