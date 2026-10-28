import Foundation

/// Pavarotti: runs note writes one after another. Each write reads the meeting when it
/// starts, so a later write (say, after the next speaker was named) always sees the
/// earlier change and is never overtaken by an older one.
public final class MeetingNoteQueue: @unchecked Sendable {
    public static let shared = MeetingNoteQueue()

    // The lock keeps taking the last write and replacing it whole.
    private let lock = NSLock()
    private var last: Task<Void, Never>?

    public init() {}

    /// Runs `work` in the background once everything enqueued before it is done.
    @discardableResult
    public func enqueue(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            let previous = last
            let next = Task.detached(priority: .utility) {
                await previous?.value
                await work()
            }
            last = next
            return next
        }
    }
}
