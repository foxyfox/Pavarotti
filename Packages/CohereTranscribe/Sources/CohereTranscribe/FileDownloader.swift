import Foundation

/// Downloads one URL to a local file. Injected so installer tests run without network.
public protocol FileDownloading: Sendable {
    /// Downloads `source` to `destination`, replacing any file there.
    /// `progress` receives the number of bytes written so far.
    func download(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws
}

/// `URLSession` download task with progress. The file lands in a temporary location and
/// is moved to `destination` before the task completes, as `URLSession` requires.
public struct URLSessionFileDownloader: FileDownloading {
    public init() {}

    public func download(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try Task.checkCancellation()
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await delegate.run(session: session, source: source)
        } onCancel: {
            session.invalidateAndCancel()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var placementError: (any Error)?

    init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(session: URLSession, source: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.withLock { self.continuation = continuation }
            session.downloadTask(with: source).resume()
        }
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite _: Int64
    ) {
        progress(totalBytesWritten)
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let error = httpError(of: downloadTask) ?? moveIntoPlace(from: location)
        lock.withLock { placementError = error }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, placementError) = lock.withLock {
            let pending = (self.continuation, self.placementError)
            self.continuation = nil
            return pending
        }
        if let failure = error ?? placementError {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }

    private func httpError(of task: URLSessionTask) -> (any Error)? {
        guard let response = task.response as? HTTPURLResponse else { return nil }
        guard !(200 ... 299).contains(response.statusCode) else { return nil }
        return CohereError.downloadFailed(
            asset: destination.lastPathComponent,
            reason: "HTTP \(response.statusCode)"
        )
    }

    private func moveIntoPlace(from location: URL) -> (any Error)? {
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            return nil
        } catch {
            return error
        }
    }
}
