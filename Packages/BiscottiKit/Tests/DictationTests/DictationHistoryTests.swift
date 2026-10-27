import Foundation
import Testing
@testable import Dictation

@Suite("Dictation history")
@MainActor
struct DictationHistoryTests {
    @Test("newest first, at most the limit")
    func keepsTheNewest() {
        let history = DictationHistory(fileURL: nil)
        for number in 1 ... DictationHistory.limit + 3 {
            history.record("Diktat \(number)")
        }
        #expect(history.entries.count == DictationHistory.limit)
        #expect(history.entries.first?.text == "Diktat \(DictationHistory.limit + 3)")
        #expect(history.entries.last?.text == "Diktat 4")

        history.clear()
        #expect(history.entries.isEmpty)
    }

    @Test("one dictation can be removed, also after a restart")
    func remove() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pavarotti-history-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let fileURL = folder.appending(path: "dictation-history.json")
        let history = DictationHistory(fileURL: fileURL)
        history.record("Erstes Diktat")
        history.record("Zweites Diktat")

        let first = try #require(history.entries.last)
        history.remove(first.id)

        #expect(history.entries.map(\.text) == ["Zweites Diktat"])
        #expect(DictationHistory(fileURL: fileURL).entries.map(\.text) == ["Zweites Diktat"])
    }

    @Test("survives a restart and starts empty from a broken file")
    func persistence() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pavarotti-history-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let fileURL = folder.appending(path: "dictation-history.json")

        let history = DictationHistory(fileURL: fileURL)
        history.record("Erstes Diktat")
        history.record("Zweites Diktat")
        let reloaded = DictationHistory(fileURL: fileURL)
        #expect(reloaded.entries.map(\.text) == ["Zweites Diktat", "Erstes Diktat"])
        #expect(reloaded.entries.map(\.id) == history.entries.map(\.id))

        try Data("kaputt".utf8).write(to: fileURL)
        #expect(DictationHistory(fileURL: fileURL).entries.isEmpty)
    }

    @Test("a menu line shows the time, the day when it is not today, and one line of text")
    func menuTitle() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let locale = Locale(identifier: "de_DE")
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 14, minute: 32)))
        let entry = DictationHistoryEntry(date: date, text: "Hallo Welt,\nzweite Zeile")

        let today = entry.menuTitle(now: date.addingTimeInterval(3600), calendar: calendar, locale: locale)
        #expect(today == "14:32 \u{2014} Hallo Welt, zweite Zeile")

        let later = entry.menuTitle(now: date.addingTimeInterval(86400 * 2), calendar: calendar, locale: locale)
        #expect(later.contains("27"))
        #expect(later.contains("14:32"))
        #expect(later.hasSuffix(" \u{2014} Hallo Welt, zweite Zeile"))
    }

    @Test("long text is cut with an ellipsis")
    func preview() {
        let long = String(repeating: "Wort ", count: 30)
        let preview = DictationHistoryEntry.preview(of: long)
        #expect(preview.count == DictationHistoryEntry.previewLength)
        #expect(preview.hasSuffix("\u{2026}"))
        #expect(DictationHistoryEntry.preview(of: "kurz") == "kurz")
    }
}

@Suite("Dictation history in the controller")
@MainActor
struct DictationControllerHistoryTests {
    @Test("a dictation is kept even when it could not be pasted")
    func keptWhenNotPasted() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.inserter.result = .copiedOnly

        #expect(await harness.startListening())
        harness.audio.samples = FakeAudioSource.speech(seconds: 1)
        harness.controller.stop()
        await harness.controller.waitForWork()

        #expect(harness.controller.history.entries.map(\.text) == ["Hallo Welt"])
    }

    @Test("nothing heard keeps nothing")
    func emptyNotKept() async {
        let harness = DictationHarness()
        defer { harness.tearDown() }
        harness.engine.state.withLock { $0.text = " " }

        #expect(await harness.startListening())
        harness.audio.samples = FakeAudioSource.speech(seconds: 1)
        harness.controller.stop()
        await harness.controller.waitForWork()

        #expect(harness.history.entries.isEmpty)
    }
}
