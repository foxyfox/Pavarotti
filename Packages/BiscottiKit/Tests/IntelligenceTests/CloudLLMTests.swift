import DataStore
import Foundation
import LocalLLM
import Testing
@testable import Intelligence

// MARK: - Fakes

/// Hands out canned response lines and records the requests.
final class FakeLineStreaming: CloudLineStreaming, @unchecked Sendable {
    var responseLines: [String]
    var failure: (any Error)?
    private(set) var requests: [URLRequest] = []

    init(lines: [String] = [], error: (any Error)? = nil) {
        responseLines = lines
        failure = error
    }

    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        let canned = responseLines
        let thrown = failure
        return AsyncThrowingStream { continuation in
            for line in canned {
                continuation.yield(line)
            }
            continuation.finish(throwing: thrown)
        }
    }
}

/// An in-memory keychain.
final class FakeSecrets: SecretStoring, @unchecked Sendable {
    var values: [String: String] = [:]

    func secret(for account: String) -> String? {
        values[account]
    }

    func setSecret(_ secret: String?, for account: String) throws {
        values[account] = secret?.isEmpty == false ? secret : nil
    }
}

private let anthropic = CloudEndpoint(
    kind: .anthropic, baseURL: CloudEndpoint.anthropicBaseURL, model: "claude-opus-5-5", apiKey: "sk-ant"
)

private func openAI(key: String = "sk-oa") -> CloudEndpoint {
    CloudEndpoint(
        kind: .openAICompatible,
        baseURL: URL(string: "http://localhost:1234/v1/") ?? CloudEndpoint.anthropicBaseURL,
        model: "qwen3",
        apiKey: key
    )
}

private func body(of request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func anthropicText(_ text: String) -> String {
    #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\#(text)"}}"#
}

private func openAIText(_ text: String) -> String {
    #"data: {"choices":[{"index":0,"delta":{"content":"\#(text)"}}]}"#
}

// MARK: - Requests

@Suite("Cloud LLM requests")
struct CloudRequestTests {
    let messages: [LLMMessage] = [
        .system("Be brief."), .user("Transcript"), .assistant(""), .user("Summary please"), .assistant("- A"), .user("Title")
    ]

    @Test("Anthropic: system apart, no sampling, server-side fallback for current models")
    func anthropicRequest() throws {
        let request = try CloudRequest.anthropic(anthropic, messages: messages)

        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let json = try body(of: request)
        #expect(json["model"] as? String == "claude-opus-5-5")
        #expect(json["system"] as? String == "Be brief.")
        #expect(json["stream"] as? Bool == true)
        #expect(json["max_tokens"] as? Int == 64000)
        #expect(json["fallbacks"] as? String == "default")
        #expect(json["temperature"] == nil)
        let turns = try #require(json["messages"] as? [[String: String]])
        #expect(turns == [
            ["role": "user", "content": "Transcript\n\nSummary please"],
            ["role": "assistant", "content": "- A"],
            ["role": "user", "content": "Title"]
        ])
    }

    @Test("Anthropic: models without server-side fallback get none")
    func anthropicWithoutFallback() throws {
        var endpoint = anthropic
        endpoint.model = "claude-haiku-4-5"
        let request = try CloudRequest.anthropic(endpoint, messages: messages)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(try body(of: request)["fallbacks"] == nil)
    }

    @Test("OpenAI-compatible: chat completions, bearer key only when set")
    func openAIRequest() throws {
        let request = try CloudRequest.openAICompatible(openAI(), messages: [.system("S"), .user("U")])
        #expect(request.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-oa")
        let json = try body(of: request)
        #expect(json["max_tokens"] == nil)
        #expect(json["temperature"] == nil)
        #expect(json["messages"] as? [[String: String]] == [["role": "system", "content": "S"], ["role": "user", "content": "U"]])

        let keyless = try CloudRequest.openAICompatible(openAI(key: ""), messages: [.user("U")])
        #expect(keyless.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

// MARK: - Streams

@Suite("Cloud LLM streams")
struct CloudStreamTests {
    @Test("Anthropic: only text deltas count, thinking and pings do not")
    func anthropicEvents() {
        let parse = { CloudStreamParser.event(fromLine: $0, kind: .anthropic) }
        #expect(parse("event: content_block_delta") == .ignored)
        #expect(parse(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hm"}}"#) == .ignored)
        #expect(parse(anthropicText("Hallo")) == .text("Hallo"))
        #expect(parse(#"data: {"type":"ping"}"#) == .ignored)
        #expect(parse(#"data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"category":"cyber"}}}"#)
            == .stop(reason: "refusal", category: "cyber"))
        #expect(parse(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) == .failure("Overloaded"))
    }

    @Test("OpenAI-compatible: content deltas, finish and errors")
    func openAIEvents() {
        let parse = { CloudStreamParser.event(fromLine: $0, kind: .openAICompatible) }
        #expect(parse(openAIText("Hi")) == .text("Hi"))
        #expect(parse(#"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#) == .stop(reason: "stop", category: nil))
        #expect(parse("data: [DONE]") == .stop(reason: nil, category: nil))
        #expect(parse(#"data: {"error":{"message":"bad model"}}"#) == .failure("bad model"))
        #expect(parse(": keep-alive") == .ignored)
    }

    @Test("A leading think block is dropped, also when its tags are split")
    func thinkFilter() {
        var filter = ThinkBlockFilter()
        let pieces = ["\n<thi", "nk>plan the ", "notes</th", "ink>\n\n", "- A", "\n- B"].map { filter.feed($0) }
        #expect(pieces.joined() + filter.finish() == "- A\n- B")

        var plain = ThinkBlockFilter()
        #expect(["<", "b>Hi</b>"].map { plain.feed($0) }.joined() + plain.finish() == "<b>Hi</b>")

        var short = ThinkBlockFilter()
        #expect(short.feed("<th") + short.finish() == "<th")
    }

    @Test("A session joins the text of all text blocks")
    func sessionText() async throws {
        let transport = FakeLineStreaming(lines: [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            anthropicText("- Ent"), anthropicText("scheidung"),
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#
        ])
        let session = CloudLLMSession(endpoint: anthropic, transport: transport)
        let text = try await session.generate(messages: [.user("U")], options: GenerationOptions())
        #expect(text == "- Entscheidung")
        #expect(transport.requests.count == 1)
    }

    @Test("A refusal fails the run instead of keeping a partial answer")
    func refusal() async {
        let transport = FakeLineStreaming(lines: [
            anthropicText("Teil"),
            #"data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":null}}"#
        ])
        let session = CloudLLMSession(endpoint: anthropic, transport: transport)
        await #expect(throws: CloudLLMError.refused(category: nil)) {
            _ = try await session.generate(messages: [.user("U")], options: GenerationOptions())
        }
    }

    @Test("HTTP errors carry the provider's message")
    func httpError() async {
        let failure = CloudLLMError.http(status: 401, message: CloudLLMError.message(fromBody: Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8)))
        let session = CloudLLMSession(endpoint: anthropic, transport: FakeLineStreaming(error: failure))
        await #expect(throws: failure) {
            _ = try await session.generate(messages: [.user("U")], options: GenerationOptions())
        }
        #expect(failure.localizedDescription == "The API key was not accepted. invalid x-api-key")
    }
}

// MARK: - Settings and routing

@Suite("Cloud LLM settings")
struct CloudLLMSettingsTests {
    private func makeStore() throws -> (CloudLLMSettingsStore, FakeSecrets) {
        let defaults = try #require(UserDefaults(suiteName: "CloudLLMSettingsTests.\(UUID().uuidString)"))
        let secrets = FakeSecrets()
        return (CloudLLMSettingsStore(defaults: defaults, secrets: secrets), secrets)
    }

    @Test("Only a complete setup gives an endpoint")
    func endpoint() throws {
        let (store, secrets) = try makeStore()
        var settings = store.load()
        #expect(settings.provider == .local)
        #expect(store.endpoint() == nil)

        settings.provider = .anthropic
        store.save(settings)
        #expect(store.endpoint() == nil)
        try store.setAPIKey(" sk-ant \n", for: .anthropic)
        #expect(secrets.values["anthropic"] == "sk-ant")
        #expect(store.endpoint() == anthropic)

        settings.provider = .openAICompatible
        settings.openAIModel = "qwen3"
        settings.openAIBaseURL = "localhost:1234"
        store.save(settings)
        #expect(store.endpoint() == nil)
        settings.openAIBaseURL = "http://localhost:1234/v1/"
        store.save(settings)
        #expect(store.endpoint() == openAI(key: ""))
    }

    @Test("Runs go to the cloud endpoint when one is set up, else to the local model")
    func routing() async throws {
        let local = FakeLLMRunner()
        let transport = FakeLineStreaming(lines: [anthropicText("OK")])
        let cloud = ProviderLLMRunner(local: local, endpoint: { anthropic }, transport: transport)
        let answer = try await cloud.withSession(model: ModelManager.cloudPlaceholderModelURL, config: .modelOnly) { session in
            try await session.generate(messages: [.user("U")], options: GenerationOptions())
        }
        #expect(answer == "OK")
        #expect(local.sessionCount == 0)

        let localOnly = ProviderLLMRunner(local: local, endpoint: { nil }, transport: transport)
        let model = URL(fileURLWithPath: "/models/gemma.gguf")
        _ = try await localOnly.withSession(model: model, config: .modelOnly) { _ in 1 }
        #expect(local.lastModelURL == model)

        await #expect(throws: CloudLLMError.self) {
            _ = try await localOnly.withSession(model: ModelManager.cloudPlaceholderModelURL, config: .modelOnly) { _ in 1 }
        }
    }

    @Test("With a cloud provider, AI runs need no downloaded model")
    @MainActor func modelManager() throws {
        let store = try DataStore(storage: .inMemory)
        let manager = ModelManager(store: store, models: FakeModelProvider(downloadedIDs: []), hardware: FakeHardwareProbe())
        #expect(!manager.isModelAvailable)
        #expect(manager.runModelURL() == nil)

        manager.cloudProviderActive = true
        #expect(manager.isModelAvailable)
        #expect(manager.runModelURL() == ModelManager.cloudPlaceholderModelURL)
    }
}
