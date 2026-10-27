import Foundation

/// Errors from installing or running the local Cohere runtime.
public enum CohereError: Error, Equatable, LocalizedError {
    case notInstalled(missing: [String])
    case downloadFailed(asset: String, reason: String)
    case checksumMismatch(asset: String)
    case extractionFailed(asset: String, status: Int32)
    case portUnavailable
    case serverExited(output: String)
    case serverStartTimedOut(output: String)
    case serverNotRunning
    case requestFailed(status: Int, body: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case let .notInstalled(missing):
            "Cohere Transcribe is not installed. Missing: \(missing.joined(separator: ", "))"
        case let .downloadFailed(asset, reason):
            "Downloading \(asset) failed: \(reason)"
        case let .checksumMismatch(asset):
            "\(asset) did not match its pinned checksum"
        case let .extractionFailed(asset, status):
            "Unpacking \(asset) failed (tar exit status \(status))"
        case .portUnavailable:
            "No free loopback port for the CrispASR server"
        case let .serverExited(output):
            "The CrispASR server stopped unexpectedly. \(output)"
        case let .serverStartTimedOut(output):
            "The CrispASR server did not become ready in time. \(output)"
        case .serverNotRunning:
            "The CrispASR server is not running"
        case let .requestFailed(status, body):
            "The CrispASR server answered \(status): \(body)"
        case .invalidResponse:
            "The CrispASR server sent a response that could not be read"
        }
    }
}
