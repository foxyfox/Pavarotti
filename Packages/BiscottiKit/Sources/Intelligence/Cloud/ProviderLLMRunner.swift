import Foundation
import LocalLLM

/// Pavarotti: runs AI sessions with the provider chosen in Settings: the cloud
/// endpoint when one is set up, otherwise the local model.
public struct ProviderLLMRunner: LLMRunning {
    private let local: any LLMRunning
    private let endpoint: @Sendable () -> CloudEndpoint?
    private let transport: any CloudLineStreaming

    /// - Parameters:
    ///   - local: Runs sessions on the downloaded model.
    ///   - endpoint: The cloud endpoint, read when each session starts.
    public init(
        local: any LLMRunning,
        endpoint: @escaping @Sendable () -> CloudEndpoint?,
        transport: any CloudLineStreaming = URLSessionLineStreaming()
    ) {
        self.local = local
        self.endpoint = endpoint
        self.transport = transport
    }

    public func withSession<T: Sendable>(
        model: URL,
        config: EngineConfig,
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T {
        if let endpoint = endpoint() {
            return try await body(CloudLLMSession(endpoint: endpoint, transport: transport))
        }
        guard model != ModelManager.cloudPlaceholderModelURL else {
            throw CloudLLMError.failed("No AI provider is set up any more. Choose one in Settings.")
        }
        return try await local.withSession(model: model, config: config, body)
    }

    /// Sends a one-line request to `endpoint` and returns the answer, to check the
    /// address, model and key from Settings.
    public static func checkConnection(
        to endpoint: CloudEndpoint,
        transport: any CloudLineStreaming = URLSessionLineStreaming()
    ) async throws -> String {
        let session = CloudLLMSession(endpoint: endpoint, transport: transport)
        let answer = try await session.generate(
            messages: [.user("Reply with the single word OK.")],
            options: GenerationOptions(maxTokens: 16)
        )
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Streams the lines of an HTTP response body.
public protocol CloudLineStreaming: Sendable {
    /// The body's lines. Fails with ``CloudLLMError/http(status:message:)`` for a
    /// status outside 200–299.
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error>
}

/// ``CloudLineStreaming`` over `URLSession`.
public struct URLSessionLineStreaming: CloudLineStreaming {
    public init() {}

    public func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200 ..< 300).contains(status) else {
                        var body = Data()
                        for try await byte in bytes where body.count < 16384 {
                            body.append(byte)
                        }
                        throw CloudLLMError.http(status: status, message: CloudLLMError.message(fromBody: body))
                    }
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Pavarotti: an AI run's session against a cloud API. Each turn is one streamed
/// request carrying the conversation so far.
struct CloudLLMSession: LLMSession {
    let endpoint: CloudEndpoint
    let transport: any CloudLineStreaming

    /// A rough count (four characters per token), only logged: providers size their
    /// context themselves.
    func countTokens(messages: [LLMMessage]) async throws -> Int {
        messages.reduce(0) { $0 + $1.content.count } / 4 + 1
    }

    func reconfigure(contextSize _: Int) async throws {}

    func generate(messages: [LLMMessage], options: GenerationOptions) async throws -> String {
        var text = ""
        for try await event in await generateStreaming(messages: messages, options: options) {
            if case let .token(piece) = event {
                text += piece
            }
        }
        return text
    }

    func generateStreaming(
        messages: [LLMMessage], options _: GenerationOptions
    ) async -> AsyncThrowingStream<StreamEvent, Error> {
        let endpoint = endpoint
        let transport = transport
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.stream(messages, to: endpoint, transport: transport) { text in
                        continuation.yield(.token(text))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sends `messages` and hands each piece of the answer's text to `onText`.
    static func stream(
        _ messages: [LLMMessage],
        to endpoint: CloudEndpoint,
        transport: any CloudLineStreaming,
        onText: (String) -> Void
    ) async throws {
        let request = try CloudRequest.make(for: endpoint, messages: messages)
        var filter = ThinkBlockFilter()
        var stopReason: String?
        var stopCategory: String?
        for try await line in transport.lines(for: request) {
            switch CloudStreamParser.event(fromLine: line, kind: endpoint.kind) {
            case let .text(text):
                let answer = endpoint.kind == .openAICompatible ? filter.feed(text) : text
                if !answer.isEmpty {
                    onText(answer)
                }
            case let .stop(reason, category):
                stopReason = reason ?? stopReason
                stopCategory = category ?? stopCategory
            case let .failure(message):
                throw CloudLLMError.failed(message)
            case .ignored:
                break
            }
        }
        let rest = filter.finish()
        if !rest.isEmpty {
            onText(rest)
        }
        // A decline after part of the answer leaves only that part: discard it.
        if stopReason == "refusal" {
            throw CloudLLMError.refused(category: stopCategory)
        }
    }
}
