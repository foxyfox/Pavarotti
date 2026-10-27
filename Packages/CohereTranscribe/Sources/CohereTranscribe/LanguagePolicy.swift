import Foundation

/// The language a transcription should be in.
public enum TranscriptionLanguage: String, Sendable, CaseIterable, Codable {
    /// Detect German or English. Anything else is transcribed as German.
    case automatic = "auto"
    case german = "de"
    case english = "en"
}

/// Decides which language to ask the server for, and when to ask again.
///
/// Cohere has no language ID of its own. In automatic mode the server's Silero model
/// detects the language first. Cohere then writes fluent text in whatever language was
/// detected, so a wrong detection (say Dutch for German) is redone in German instead
/// of being passed on.
enum LanguagePolicy {
    static let accepted: Set<String> = ["de", "en"]
    static let fallback = "de"

    /// The language for the first request.
    static func firstRequest(for language: TranscriptionLanguage, detectionAvailable: Bool) -> String {
        switch language {
        case .automatic: detectionAvailable ? "auto" : fallback
        case .german, .english: language.rawValue
        }
    }

    /// The language to redo the request in, or `nil` when the answer can be kept.
    /// Only an automatic request is ever redone.
    static func retryLanguage(afterRequesting requested: String, detected: String?) -> String? {
        guard requested == "auto" else { return nil }
        guard let code = normalized(detected), accepted.contains(code) else { return fallback }
        return nil
    }

    /// The language the text of the last request is in.
    static func resolvedLanguage(requested: String, detected: String?) -> String {
        guard requested == "auto" else { return requested }
        guard let code = normalized(detected), accepted.contains(code) else { return fallback }
        return code
    }

    /// Lowercase ISO 639-1 code from values like `de`, `de-DE`, `German`.
    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let lowered = value.trimmingCharacters(in: .whitespaces).lowercased()
        let names = ["german": "de", "deutsch": "de", "english": "en"]
        if let code = names[lowered] {
            return code
        }
        let parts = lowered.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        guard let primary = parts.first, primary != "auto", primary != "und" else { return nil }
        return String(primary)
    }
}
