import Foundation

/// The language a transcription should be in: automatic, or one the model knows
/// (see ``CohereModel/languages``).
public struct TranscriptionLanguage: RawRepresentable, Hashable, Sendable, Codable {
    /// `auto`, or a lowercase ISO 639-1 code such as `de`.
    public let rawValue: String

    /// Accepts `auto` and two-letter lowercase codes.
    public init?(rawValue: String) {
        let isCode = rawValue.count == 2 && rawValue.allSatisfy { $0.isASCII && $0.isLowercase }
        guard rawValue == "auto" || isCode else { return nil }
        self.rawValue = rawValue
    }

    private init(code: String) {
        rawValue = code
    }

    /// Detect German or English. Anything else is transcribed as German.
    public static let automatic = TranscriptionLanguage(code: "auto")
    public static let german = TranscriptionLanguage(code: "de")
    public static let english = TranscriptionLanguage(code: "en")

    /// The ISO 639-1 code, `nil` in automatic mode.
    public var code: String? {
        rawValue == "auto" ? nil : rawValue
    }

    /// Stored as the plain code, as the earlier enum was.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let language = TranscriptionLanguage(rawValue: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a language: \(text)")
        }
        self = language
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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
        guard let code = language.code else { return detectionAvailable ? "auto" : fallback }
        return code
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

    /// The language of a model that writes what it hears (Parakeet): the detected one (in
    /// automatic mode only German or English), else the requested one, else German.
    static func heardLanguage(requested: String, detected: String?) -> String {
        if let code = normalized(detected), requested != "auto" || accepted.contains(code) {
            return code
        }
        return requested == "auto" ? fallback : requested
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
