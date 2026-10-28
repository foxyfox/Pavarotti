import Foundation
import Testing
@testable import MeetingNotes

@Suite("Meeting note queue")
struct MeetingNoteQueueTests {
    /// Collects the order in which writes ran.
    private actor Log {
        var entries: [String] = []

        func append(_ entry: String) {
            entries.append(entry)
        }
    }

    @Test("Writes run one after another, in the order they came in")
    func runsInOrder() async {
        let queue = MeetingNoteQueue()
        let log = Log()

        queue.enqueue {
            await log.append("first starts")
            try? await Task.sleep(for: .milliseconds(100))
            await log.append("first ends")
        }
        let last = queue.enqueue {
            await log.append("second")
        }
        await last.value

        #expect(await log.entries == ["first starts", "first ends", "second"])
    }
}
