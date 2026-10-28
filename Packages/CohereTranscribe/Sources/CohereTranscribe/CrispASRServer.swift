import Darwin
import Foundation
import os

/// Runs `crispasr --server` with the model's backend (Cohere or Parakeet) on a loopback port.
///
/// The server keeps the model loaded on Metal, so dictations after the first one only
/// pay for inference. It is started through a small shell guard that stops it when
/// this process goes away, even after a crash, so no orphan keeps gigabytes of RAM.
public actor CrispASRServer {
    /// Everything needed to start the server.
    public struct Configuration: Sendable, Equatable {
        public let executable: URL
        public let model: URL
        public let modelID: String
        public let backend: CohereModel.Backend
        public let voiceActivityModel: URL
        /// Silero language ID. Without it the server cannot detect the language.
        public let languageIdentificationModel: URL?
        /// CTC aligner for word times (see ``CohereAssetCatalog/wordAligner``). Without it
        /// the server spreads each chunk's words evenly over the chunk.
        public let wordAligner: URL?
        public let cacheDirectory: URL
        public let threads: Int

        public init(
            executable: URL,
            model: URL,
            modelID: String,
            backend: CohereModel.Backend = .cohere,
            voiceActivityModel: URL,
            languageIdentificationModel: URL?,
            wordAligner: URL? = nil,
            cacheDirectory: URL,
            threads: Int = Configuration.recommendedThreads
        ) {
            self.executable = executable
            self.model = model
            self.modelID = modelID
            self.backend = backend
            self.voiceActivityModel = voiceActivityModel
            self.languageIdentificationModel = languageIdentificationModel
            self.wordAligner = wordAligner
            self.cacheDirectory = cacheDirectory
            self.threads = threads
        }

        /// Leaves two cores for the rest of the system, at most eight threads.
        public static var recommendedThreads: Int {
            max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        }

        /// Command line for `crispasr`, without the executable.
        func arguments(port: UInt16) -> [String] {
            var arguments = [
                "--server",
                "--backend", backend.rawValue,
                "--model", model.path,
                "--host", "127.0.0.1",
                "--port", String(port),
                "--language", "en",
                "--vad",
                "--vad-model", voiceActivityModel.path,
                "--strict-pipeline",
                "--require-vad",
                "--threads", String(threads),
                "--gpu-backend", "metal"
            ]
            if let wordAligner {
                // Cohere has rough word times of its own; the aligner replaces them.
                arguments += ["--aligner-model", wordAligner.path, "--force-aligner"]
            }
            if let languageIdentificationModel {
                arguments += ["--lid-backend", "silero", "--lid-model", languageIdentificationModel.path]
            }
            return arguments
        }
    }

    public let configuration: Configuration
    private let apiKey = UUID().uuidString
    private let output = OutputTail()
    private var process: Process?
    private var endpoint: URL?
    private var startup: Task<Void, any Error>?
    private static let logger = Logger(subsystem: "de.foxagon.pavarotti", category: "CrispASR")
    private static let startupTimeout: Duration = .seconds(90)

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Whether the server process is up and answered its health check.
    public var isRunning: Bool {
        guard let process, endpoint != nil else { return false }
        return process.isRunning
    }

    /// Whether requests may ask for automatic language detection.
    public var detectsLanguage: Bool {
        configuration.languageIdentificationModel != nil
    }

    /// Starts the server and waits until it is ready. Does nothing if it already runs.
    /// Concurrent callers share one startup.
    public func start() async throws {
        if isRunning { return }
        if let startup {
            try await startup.value
            return
        }
        let task = Task { try await launch() }
        startup = task
        defer { startup = nil }
        try await task.value
    }

    private func launch() async throws {
        stop()
        let port = try LoopbackPort.reserve()
        let process = makeProcess(port: port)
        try FileManager.default.createDirectory(
            at: configuration.cacheDirectory,
            withIntermediateDirectories: true
        )
        try process.run()
        self.process = process
        let endpoint = try LoopbackPort.url(port: port)
        do {
            try await waitUntilReady(process: process, endpoint: endpoint)
        } catch {
            stop()
            throw error
        }
        self.endpoint = endpoint
        Self.logger.info("CrispASR \(CohereAssetCatalog.crispASRVersion, privacy: .public) ready on port \(port)")
    }

    /// Stops the server. Safe to call when it is not running.
    public func stop() {
        endpoint = nil
        guard let process else { return }
        self.process = nil
        if let pipe = process.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        if process.isRunning {
            // The shell guard forwards SIGTERM to crispasr and waits for it.
            process.terminate()
        }
    }

    /// Sends one upload and returns the server's answer.
    func transcribe(_ request: TranscriptionRequest) async throws -> ServerTranscription {
        guard isRunning, let endpoint else { throw CohereError.serverNotRunning }
        let (data, response) = try await URLSession.shared.data(
            for: request.urlRequest(endpoint: endpoint, apiKey: apiKey)
        )
        guard let http = response as? HTTPURLResponse else { throw CohereError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: data.prefix(2000), encoding: .utf8) ?? ""
            throw CohereError.requestFailed(status: http.statusCode, body: body)
        }
        return try ServerTranscription.decode(data)
    }

    // MARK: - Private

    private func makeProcess(port: UInt16) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let guardArguments = ["-c", ParentGuard.script, "crispasr-guard", String(getpid()), configuration.executable.path]
        process.arguments = guardArguments + configuration.arguments(port: port)
        process.currentDirectoryURL = configuration.executable.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["CRISPASR_API_KEYS"] = apiKey
        environment["CRISPASR_CACHE_DIR"] = configuration.cacheDirectory.path
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let tail = output
        let logger = Self.logger
        tail.reset()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            tail.append(text)
            logger.debug("\(text, privacy: .public)")
        }
        return process
    }

    private func waitUntilReady(process: Process, endpoint: URL) async throws {
        var health = URLRequest(url: endpoint.appending(path: "health"))
        health.timeoutInterval = 2
        let deadline = ContinuousClock.now.advanced(by: Self.startupTimeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process.isRunning else { throw CohereError.serverExited(output: output.text) }
            let response = try? await URLSession.shared.data(for: health).1
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw CohereError.serverStartTimedOut(output: output.text)
    }
}

/// Shell wrapper that runs the server as a child and stops it when the watched
/// parent process exits or the wrapper itself is terminated.
/// Arguments: parent PID, then the command to run.
enum ParentGuard {
    static let script = """
    watched="$1"
    shift
    "$@" &
    server=$!
    stop_server() {
      kill -TERM "$server" 2>/dev/null
      wait "$server" 2>/dev/null
    }
    trap 'stop_server; exit 143' TERM INT
    while kill -0 "$watched" 2>/dev/null; do
      if ! kill -0 "$server" 2>/dev/null; then
        wait "$server"
        exit $?
      fi
      sleep 0.5
    done
    stop_server
    """
}

/// The last few kilobytes of server output, for error messages.
final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private let limit = 8000

    var text: String {
        lock.withLock { buffer }
    }

    func append(_ text: String) {
        lock.withLock {
            buffer += text
            if buffer.count > limit {
                buffer = String(buffer.suffix(limit))
            }
        }
    }

    func reset() {
        lock.withLock { buffer = "" }
    }
}

/// Picks a free TCP port on 127.0.0.1 by binding to port 0 and reading it back.
enum LoopbackPort {
    static func reserve() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CohereError.portUnavailable }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        guard bound == 0 else { throw CohereError.portUnavailable }
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw CohereError.portUnavailable }
        return UInt16(bigEndian: address.sin_port)
    }

    static func url(port: UInt16) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        guard let url = components.url else { throw CohereError.portUnavailable }
        return url
    }
}
