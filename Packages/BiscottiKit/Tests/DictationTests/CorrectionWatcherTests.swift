import Foundation
import Testing
@testable import Dictation

@Suite("CorrectionWatcher")
@MainActor
struct CorrectionWatcherTests {
    private let cohen = DetectedCorrection(original: "Cohen", replacement: "Cohere")

    @Test("Return or Tab reports the fix")
    func commitSignal() {
        let fixture = WatchFixture()
        fixture.watch("Cohen ist da", in: "Notiz: Cohen ist da")
        #expect(fixture.watcher.isWatching)
        #expect(fixture.signals.startCount == 1)

        fixture.field.value = "Notiz: Cohere ist da"
        fixture.signals.commit()

        #expect(fixture.reported == [cohen])
        #expect(!fixture.watcher.isWatching)
        #expect(fixture.signals.stopCount == 1)
    }

    @Test("moving to another field reports the last fix seen")
    func focusChange() async {
        let fixture = WatchFixture(pollInterval: .milliseconds(5))
        fixture.watch("Cohen ist da", in: "Cohen ist da")

        fixture.field.value = "Cohere ist da"
        #expect(await fixture.nextPoll())
        fixture.field.id = "search field"
        fixture.field.value = "something else"

        #expect(await eventually { !fixture.reported.isEmpty })
        #expect(fixture.reported == [cohen])
        #expect(!fixture.watcher.isWatching)
    }

    @Test("typing on after the pasted text keeps the fix")
    func stickyFix() async {
        let fixture = WatchFixture(pollInterval: .milliseconds(5))
        fixture.watch("Cohen ist da", in: "Cohen ist da")

        fixture.field.value = "Cohere ist da"
        #expect(await fixture.nextPoll())
        fixture.field.value = "Cohere ist da und noch viel mehr Text"
        #expect(await fixture.nextPoll())
        fixture.watcher.finish()

        #expect(fixture.reported == [cohen])
    }

    @Test("an undone fix is not reported")
    func undoneFix() async {
        let fixture = WatchFixture(pollInterval: .milliseconds(5))
        fixture.watch("Cohen ist da", in: "Cohen ist da")

        fixture.field.value = "Cohere ist da"
        #expect(await fixture.nextPoll())
        fixture.field.value = "Cohen ist da"
        #expect(await fixture.nextPoll())
        fixture.signals.commit()

        #expect(fixture.reported.isEmpty)
    }

    @Test("the timeout ends the watch without reporting")
    func timeout() async {
        let fixture = WatchFixture(pollInterval: .milliseconds(5), timeout: .milliseconds(40))
        fixture.watch("Cohen ist da", in: "Cohen ist da")
        fixture.field.value = "Cohere ist da"

        #expect(await eventually { !fixture.watcher.isWatching })
        #expect(fixture.reported.isEmpty)
        #expect(fixture.signals.stopCount == 1)
    }

    @Test("a new watch first finishes the previous one, finishing twice reports once")
    func newWatchFinishesOld() {
        let fixture = WatchFixture()
        fixture.watch("Cohen ist da", in: "Cohen ist da")
        fixture.field.value = "Cohere ist da"

        fixture.watch("Cohere ist da", in: "Cohere ist da")
        #expect(fixture.reported == [cohen])
        #expect(fixture.watcher.isWatching)
        fixture.watcher.stop()
        fixture.watcher.finish()
        #expect(fixture.reported == [cohen])
    }

    @Test("unreadable fields, other text and huge fields are not watched")
    func notWatched() {
        let fixture = WatchFixture()
        fixture.watch("Cohen ist da", in: nil)
        #expect(!fixture.watcher.isWatching)

        fixture.watch("Cohen ist da", in: "the paste did not land here")
        #expect(!fixture.watcher.isWatching)

        let huge = String(repeating: "a ", count: CorrectionWatcher.maximumFieldLength) + "Cohen ist da"
        fixture.watch("Cohen ist da", in: huge)
        #expect(!fixture.watcher.isWatching)
        #expect(fixture.signals.startCount == 0)
    }
}

/// A watcher on a fake field, collecting what it reports. The default poll interval is
/// long, so polling stays out of the way unless a test wants it.
@MainActor
final class WatchFixture {
    let field = FakeFocusedField()
    let signals = FakeCommitSignals()
    let watcher: CorrectionWatcher
    private(set) var reported: [DetectedCorrection] = []

    init(pollInterval: Duration = .seconds(60), timeout: Duration = .seconds(45)) {
        watcher = CorrectionWatcher(reader: field, signals: signals, pollInterval: pollInterval, timeout: timeout)
    }

    /// Puts `value` in the field, as right after pasting `inserted`, and starts watching.
    func watch(_ inserted: String, in value: String?) {
        field.value = value
        watcher.watch(inserted: inserted) { [weak self] correction in
            self?.reported.append(correction)
        }
    }

    /// Waits until the watcher has read the field once more.
    func nextPoll() async -> Bool {
        let reads = field.readCount
        return await eventually { self.field.readCount > reads }
    }
}

/// A focused field whose text the test sets.
@MainActor
final class FakeFocusedField: FocusedTextReading {
    var id = "notes"
    /// `nil` means nothing readable has focus.
    var value: String?
    private(set) var readCount = 0

    func focusedText() -> FocusedText? {
        readCount += 1
        return value.map { FocusedText(field: id, value: $0) }
    }
}

/// Commit signals the test fires by hand.
@MainActor
final class FakeCommitSignals: CommitSignalMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onCommit: (@MainActor @Sendable () -> Void)?

    func start(onCommit: @escaping @MainActor @Sendable () -> Void) {
        startCount += 1
        self.onCommit = onCommit
    }

    func stop() {
        stopCount += 1
        onCommit = nil
    }

    /// Simulates Return, Tab or a switch to another app.
    func commit() {
        onCommit?()
    }
}
