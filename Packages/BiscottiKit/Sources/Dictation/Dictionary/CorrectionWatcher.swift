import Foundation

/// The focused text field as Accessibility reports it.
public struct FocusedText {
    /// Equal for the same field, different for another one.
    public let field: AnyHashable
    public let value: String

    public init(field: AnyHashable, value: String) {
        self.field = field
        self.value = value
    }
}

/// Reads the text of the focused field in whatever app is in front.
@MainActor
public protocol FocusedTextReading: AnyObject {
    /// `nil` when nothing readable has focus (or it is a password field).
    func focusedText() -> FocusedText?
}

/// Tells when the user is done with a field: Return, Tab or a switch to another app.
@MainActor
public protocol CommitSignalMonitoring: AnyObject {
    func start(onCommit: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

/// Follows the field that dictation pasted into and reports the word the user fixed.
///
/// After pasting it reads the field a few times a second. When the user presses Return
/// or Tab, moves to another field or app, or starts the next dictation, the last fix
/// inside the pasted text is reported. Nothing is reported after the timeout, and
/// nothing is kept: the field's text only lives in memory while watching.
@MainActor
public final class CorrectionWatcher: CorrectionWatching {
    public static let defaultPollInterval = Duration.milliseconds(250)
    public static let defaultTimeout = Duration.seconds(45)
    /// Fields longer than this (large documents) are not watched.
    static let maximumFieldLength = 20000

    private struct Session {
        let inserted: String
        let baseline: FocusedText
        var latest: DetectedCorrection?
        let onCorrection: @MainActor (DetectedCorrection) -> Void
    }

    private let reader: any FocusedTextReading
    private let signals: any CommitSignalMonitoring
    private let pollInterval: Duration
    private let timeout: Duration
    private var session: Session?
    private var pollTask: Task<Void, Never>?

    public init(
        reader: any FocusedTextReading,
        signals: any CommitSignalMonitoring,
        pollInterval: Duration = defaultPollInterval,
        timeout: Duration = defaultTimeout
    ) {
        self.reader = reader
        self.signals = signals
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    /// Whether a field is being watched right now.
    public var isWatching: Bool {
        session != nil
    }

    public func watch(inserted: String, onCorrection: @escaping @MainActor (DetectedCorrection) -> Void) {
        finish()
        guard !inserted.isEmpty,
              let baseline = reader.focusedText(),
              baseline.value.count <= Self.maximumFieldLength,
              baseline.value.contains(inserted)
        else {
            return
        }
        session = Session(inserted: inserted, baseline: baseline, latest: nil, onCorrection: onCorrection)
        signals.start { [weak self] in
            self?.finish()
        }
        let interval = pollInterval
        let limit = timeout
        pollTask = Task { [weak self] in
            var waited = Duration.zero
            while waited < limit {
                try? await Task.sleep(for: interval)
                waited += interval
                guard !Task.isCancelled, let self, poll() else { return }
            }
            self?.stop()
        }
    }

    public func finish() {
        guard let current = session else { return }
        endSession()
        let fresh = reader.focusedText().flatMap { field in
            field.field == current.baseline.field ? detect(in: field.value, for: current) : nil
        }
        if let correction = fresh ?? current.latest {
            current.onCorrection(correction)
        }
    }

    public func stop() {
        endSession()
    }

    /// Reads the field once. Returns false when the watch is over.
    private func poll() -> Bool {
        guard var current = session else { return false }
        // Not readable right now, for example while a menu is open.
        guard let field = reader.focusedText() else { return true }
        guard field.field == current.baseline.field else {
            // Focus moved on: the user is done with the field.
            finish()
            return false
        }
        if let detected = detect(in: field.value, for: current) {
            current.latest = detected
        } else if field.value == current.baseline.value {
            // The fix was undone.
            current.latest = nil
        }
        // Otherwise keep the last fix: typing on after the pasted text hides it from
        // the comparison, but it still stands.
        session = current
        return true
    }

    private func detect(in value: String, for current: Session) -> DetectedCorrection? {
        guard value.count <= Self.maximumFieldLength else { return nil }
        return CorrectionDetector.correction(inserted: current.inserted, before: current.baseline.value, after: value)
    }

    private func endSession() {
        session = nil
        pollTask?.cancel()
        pollTask = nil
        signals.stop()
    }
}
