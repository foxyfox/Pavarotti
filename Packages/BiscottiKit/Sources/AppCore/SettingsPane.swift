import Foundation

/// Pavarotti: the pages of Settings, so each stays short. Settings remembers the last one
/// in user defaults; other screens can open Settings on a given page.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case dictation
    case meetings
    case intelligence
    case general

    /// The user defaults key for the page Settings shows.
    public static let defaultsKey = "pavarotti.settings.pane"

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .dictation: String(localized: "Dictation")
        case .meetings: String(localized: "Meetings")
        case .intelligence: String(localized: "AI")
        case .general: String(localized: "General")
        }
    }

    /// SF Symbol for the page's button.
    public var systemImage: String {
        switch self {
        case .dictation: "mic"
        case .meetings: "person.2"
        case .intelligence: "sparkles"
        case .general: "gearshape"
        }
    }

    /// One line on what the page holds.
    public var caption: String {
        switch self {
        case .dictation: String(localized: "Push-to-talk, microphone, sounds, the recording bubble and your dictionary.")
        case .meetings: String(localized: "Recording, notifications, meeting notes, vocabulary and calendars.")
        case .intelligence: String(localized: "Summaries and speaker names, on this Mac or with a cloud model.")
        case .general: String(localized: "Startup, updates, permissions, and import and export.")
        }
    }
}

public extension AppCore {
    /// Pavarotti: routes to Settings, on `pane`.
    func showSettings(_ pane: SettingsPane, defaults: UserDefaults = .standard) {
        defaults.set(pane.rawValue, forKey: SettingsPane.defaultsKey)
        showSettings()
    }
}
