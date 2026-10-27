import Foundation

/// Reads audio and video files as mono samples, for file transcription.
public protocol AudioFileReading: Sendable {
    /// The length of the audio in seconds. Throws when the file has no audio Pavarotti
    /// can read.
    func duration(of url: URL) async throws -> TimeInterval
    /// The audio as mono samples at `sampleRate`, in pieces of any length.
    func samples(of url: URL, sampleRate: Int) -> AsyncThrowingStream<[Float], any Error>
}

/// Errors file transcription reports to the user.
public enum FileTranscriptionError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case noAudio(String)
    case nothingHeard(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(name):
            "Pavarotti cannot read \u{201C}\(name)\u{201D}. Choose an audio or video file, such as M4A, MP3, WAV or MOV."
        case let .noAudio(name):
            "\u{201C}\(name)\u{201D} has no sound."
        case let .nothingHeard(name):
            "No speech was found in \u{201C}\(name)\u{201D}."
        }
    }
}
