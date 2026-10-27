import Foundation
import LocalLLM

/// Pavarotti: what went wrong in a cloud AI run, in words for the meeting's AI status.
public enum CloudLLMError: LocalizedError, Equatable {
    case http(status: Int, message: String)
    case refused(category: String?)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case let .http(status, message):
            let reason = switch status {
            case 401: "The API key was not accepted."
            case 403: "The API key may not use this model."
            case 404: "The model or address was not found."
            case 429: "The provider's rate limit was hit; try again later."
            default: "The provider answered with HTTP \(status)."
            }
            return message.isEmpty ? reason : "\(reason) \(message)"
        case let .refused(category):
            return "The model declined the request" + (category.map { " (\($0))." } ?? ".")
        case let .failed(message):
            return message
        }
    }

    /// The `error.message` of a JSON error body, or the start of the body as text.
    static func message(fromBody body: Data) -> String {
        if let message = (try? JSONDecoder().decode(APIErrorBody.self, from: body))?.error?.message {
            return message
        }
        let text = String(data: body, encoding: .utf8) ?? ""
        return String(text.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One server-sent event of a streamed answer, reduced to what an AI run needs.
enum CloudStreamEvent: Equatable {
    /// A piece of the answer's text.
    case text(String)
    /// Why the answer stopped (`end_turn`, `max_tokens`, `refusal`, ...).
    case stop(reason: String?, category: String?)
    case failure(String)
    /// Thinking, pings, metadata.
    case ignored
}

// MARK: - Requests

/// The HTTP requests of both API styles. Requests always stream: answers to long
/// transcripts can take minutes, and a stream keeps the connection busy.
enum CloudRequest {
    /// The Anthropic API version the requests are written for (no sampling parameters).
    static let anthropicVersion = "2026-10-21"
    /// Room for adaptive thinking plus long notes; only what is used is billed.
    static let anthropicMaxTokens = 64000
    /// Seconds without any data before a request fails.
    static let idleTimeout: TimeInterval = 180

    /// Models that take `fallbacks: "default"`: a classifier decline is retried
    /// server-side on Anthropic's recommended model instead of failing the run.
    static let modelsWithServerFallback: Set = [
        "claude-fable-5-1", "claude-fable-5", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"
    ]

    static func make(for endpoint: CloudEndpoint, messages: [LLMMessage]) throws -> URLRequest {
        switch endpoint.kind {
        case .anthropic: try anthropic(endpoint, messages: messages)
        case .openAICompatible: try openAICompatible(endpoint, messages: messages)
        }
    }

    static func anthropic(_ endpoint: CloudEndpoint, messages: [LLMMessage]) throws -> URLRequest {
        var request = URLRequest(url: endpoint.baseURL.appending(path: "messages"), timeoutInterval: idleTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(endpoint.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")

        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var body: [String: Any] = [
            "model": endpoint.model,
            "max_tokens": anthropicMaxTokens,
            "stream": true,
            "messages": conversation(messages).map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        if !system.isEmpty {
            body["system"] = system
        }
        if modelsWithServerFallback.contains(endpoint.model) {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func openAICompatible(_ endpoint: CloudEndpoint, messages: [LLMMessage]) throws -> URLRequest {
        var request = URLRequest(url: endpoint.baseURL.appending(path: "chat/completions"), timeoutInterval: idleTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !endpoint.apiKey.isEmpty {
            request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        // No token limit or temperature: reasoning models reject them, and the
        // server's defaults suit notes.
        let body: [String: Any] = [
            "model": endpoint.model,
            "stream": true,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// The user and assistant turns as the Messages API takes them: no empty turns,
    /// and turns of the same role joined (an empty answer would otherwise leave two
    /// user turns in a row).
    static func conversation(_ messages: [LLMMessage]) -> [LLMMessage] {
        var turns: [LLMMessage] = []
        for message in messages where message.role != .system {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            if let last = turns.last, last.role == message.role {
                turns[turns.count - 1] = LLMMessage(role: last.role, content: last.content + "\n\n" + content)
            } else {
                turns.append(LLMMessage(role: message.role, content: content))
            }
        }
        return turns
    }
}

// MARK: - Streams

/// Reads the `data:` lines of both APIs' server-sent events.
enum CloudStreamParser {
    static func event(fromLine line: String, kind: CloudEndpoint.Kind) -> CloudStreamEvent {
        guard line.hasPrefix("data:") else { return .ignored }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        switch kind {
        case .anthropic: return anthropic(payload)
        case .openAICompatible: return openAICompatible(payload)
        }
    }

    /// Text deltas of text blocks; thinking blocks, signatures, pings and the
    /// server-side fallback marker are left out. All text blocks count, also when a
    /// thinking block comes first (the fork's fix for notes falling back to another
    /// model).
    static func anthropic(_ payload: String) -> CloudStreamEvent {
        guard let event = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: Data(payload.utf8)) else { return .ignored }
        switch event.type {
        case "content_block_delta":
            guard event.delta?.type == "text_delta", let text = event.delta?.text else { return .ignored }
            return .text(text)
        case "message_delta":
            guard let reason = event.delta?.stopReason else { return .ignored }
            return .stop(reason: reason, category: event.delta?.stopDetails?.category)
        case "error":
            return .failure(event.error?.message ?? "The provider reported an error.")
        default:
            return .ignored
        }
    }

    static func openAICompatible(_ payload: String) -> CloudStreamEvent {
        if payload == "[DONE]" {
            return .stop(reason: nil, category: nil)
        }
        guard let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: Data(payload.utf8)) else { return .ignored }
        if let error = chunk.error {
            return .failure(error.message ?? "The server reported an error.")
        }
        guard let choice = chunk.choices?.first else { return .ignored }
        if let text = choice.delta?.content, !text.isEmpty {
            return .text(text)
        }
        if let reason = choice.finishReason {
            return .stop(reason: reason, category: nil)
        }
        return .ignored
    }
}

/// Drops a leading `<think>…</think>` block that reasoning models behind
/// OpenAI-compatible servers put into the answer text, also when the tags are split
/// across stream chunks.
struct ThinkBlockFilter {
    private enum State {
        case undecided
        case thinking
        case afterThinking
        case passing
    }

    private static let open = "<think>"
    private static let close = "</think>"
    private var state = State.undecided
    private var buffer = ""

    /// The part of `chunk` that belongs to the answer.
    mutating func feed(_ chunk: String) -> String {
        switch state {
        case .passing:
            return chunk
        case .afterThinking:
            return skippingLeadingWhitespace(chunk)
        case .thinking:
            buffer += chunk
            return closeThinking()
        case .undecided:
            buffer += chunk
            let start = buffer.drop { $0.isWhitespace }
            if start.hasPrefix(Self.open) {
                buffer = String(start.dropFirst(Self.open.count))
                state = .thinking
                return closeThinking()
            }
            if Self.open.hasPrefix(start) {
                return ""
            }
            state = .passing
            defer { buffer = "" }
            return buffer
        }
    }

    /// What is still held back when the stream ends.
    mutating func finish() -> String {
        defer { buffer = "" }
        return state == .undecided ? buffer : ""
    }

    private mutating func closeThinking() -> String {
        guard let end = buffer.range(of: Self.close) else { return "" }
        let rest = String(buffer[end.upperBound...])
        buffer = ""
        state = .afterThinking
        return skippingLeadingWhitespace(rest)
    }

    private mutating func skippingLeadingWhitespace(_ text: String) -> String {
        let rest = text.drop { $0.isWhitespace }
        if !rest.isEmpty {
            state = .passing
        }
        return String(rest)
    }
}

// MARK: - Wire types

private struct APIErrorDetail: Decodable {
    let message: String?
}

private struct APIErrorBody: Decodable {
    let error: APIErrorDetail?
}

private struct AnthropicStreamEvent: Decodable {
    let type: String
    let delta: AnthropicDelta?
    let error: APIErrorDetail?
}

private struct AnthropicDelta: Decodable {
    let type: String?
    let text: String?
    let stopReason: String?
    let stopDetails: AnthropicStopDetails?

    enum CodingKeys: String, CodingKey {
        case type, text
        case stopReason = "stop_reason"
        case stopDetails = "stop_details"
    }
}

private struct AnthropicStopDetails: Decodable {
    let category: String?
}

private struct OpenAIStreamChunk: Decodable {
    let choices: [OpenAIChoice]?
    let error: APIErrorDetail?
}

private struct OpenAIChoice: Decodable {
    let delta: OpenAIDelta?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

private struct OpenAIDelta: Decodable {
    let content: String?
}
