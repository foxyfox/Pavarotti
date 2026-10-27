import Foundation

/// The request payload for `TranscriberServiceProtocol.processAudio(requestData:reply:)`.
///
/// Bundles the audio paths and custom vocabulary into a single
/// JSON-encoded `Data` blob for transport across the XPC boundary. This keeps
/// the `@objc` protocol's parameter count within lint limits while remaining
/// fully `Codable`.
public struct XPCProcessRequest: Codable {
    public let micPath: String
    public let systemPath: String
    public let customVocabulary: [String]
    /// Pavarotti: a transcript made by Cohere in the app. When set, the worker only
    /// diarizes and never loads WhisperKit.
    public let transcript: ProvidedTranscript?

    public init(
        micPath: String,
        systemPath: String,
        customVocabulary: [String],
        transcript: ProvidedTranscript? = nil
    ) {
        self.micPath = micPath
        self.systemPath = systemPath
        self.customVocabulary = customVocabulary
        self.transcript = transcript
    }
}
