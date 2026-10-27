import Foundation

// MARK: - Learning from corrections

extension DictationController {
    /// How long the indicator shows a notice (seconds).
    static let noticeDuration = 3.0

    /// Follows the field the text went into, so a word the user fixes there is learned.
    func watchForCorrections(after text: String) {
        dependencies.corrections.watch(inserted: text) { [weak self] correction in
            self?.learn(correction)
        }
    }

    /// Adds a correction to the dictionary and tells the user.
    func learn(_ correction: DetectedCorrection) {
        guard settings.isEnabled, settings.learnsFromCorrections else { return }
        switch dependencies.dictionary.learn(correction) {
        case let .added(entry), let .updated(entry):
            showNotice("Added to the dictionary: \(entry.original) \u{2192} \(entry.replacement)")
        case let .removed(entry):
            showNotice("Removed from the dictionary: \(entry.original) \u{2192} \(entry.replacement)")
        case .unchanged:
            break
        }
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.noticeDuration))
            guard let self, !Task.isCancelled, notice == text else { return }
            notice = nil
        }
    }
}

public extension DictationController {
    /// The user's corrections, for the dictionary editor in Settings.
    var dictionary: PersonalDictionary {
        dependencies.dictionary
    }
}
