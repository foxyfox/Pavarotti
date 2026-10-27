import CryptoKit
import Foundation

/// Streaming SHA-256 of a file, so multi-GB models are never read into memory at once.
enum FileDigest {
    static let chunkSize = 4 * 1024 * 1024

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
