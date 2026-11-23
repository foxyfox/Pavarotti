import Dictation
import Foundation
import Intelligence
import LocalLLM
import Testing
@testable import AppCore

/// Records the model, context size and messages of each session and answers with a fixed note.
private final class RecordingRunner: LLMRunning, @unchecked Sendable {
    let lock = NSLock()
    var models: [URL] = []
    var contextSizes: [Int] = []
    var messages: [[LLMMessage]] = []
    var maxTokens: [Int] = []
    let answer: String

    init(answer: String) {
        self.answer = answer
    }

    func withSession<T: Sendable>(
        model: URL,
        config _: EngineConfig,
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T {
        lock.withLock { models.append(model) }
        return try await body(Session(runner: self))
    }

    private struct Session: LLMSession {
        let runner: RecordingRunner

        func countTokens(messages _: [LLMMessage]) async throws -> Int {
            300
        }

        func reconfigure(contextSize: Int) async throws {
            runner.lock.withLock { runner.contextSizes.append(contextSize) }
        }

        func generate(messages: [LLMMessage], options: GenerationOptions) async throws -> String {
            runner.lock.withLock {
                runner.messages.append(messages)
                runner.maxTokens.append(options.maxTokens)
            }
            return runner.answer
        }

        func generateStreaming(
            messages _: [LLMMessage], options _: GenerationOptions
        ) async -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }
}

@Suite("BraindumpStructurer")
@MainActor
struct BraindumpStructurerTests {
    private let localModel = URL(fileURLWithPath: "/tmp/model.gguf")

    @Test("the local model structures the dictation when one is downloaded")
    func usesTheLocalModel() async throws {
        let local = RecordingRunner(answer: "## Lokal")
        let cloud = RecordingRunner(answer: "## Cloud")
        let model = localModel
        let structurer = BraindumpStructurer(
            local: local, cloud: cloud,
            localModel: { model },
            cloudAvailable: { true }
        )

        let note = try await structurer.structure("einkaufen und dann den Bericht schreiben")

        #expect(note == "## Lokal")
        #expect(local.models == [localModel])
        #expect(cloud.models.isEmpty)
        #expect(local.contextSizes == [300 + 1024 + 256])
        #expect(local.maxTokens == [1024])
        let sent = try #require(local.messages.first)
        #expect(sent.first == LLMMessage.system(Braindump.systemPrompt))
        #expect(sent.last?.content.hasSuffix("einkaufen und dann den Bericht schreiben") == true)
    }

    @Test("without a local model the cloud provider structures it")
    func fallsBackToTheCloud() async throws {
        let local = RecordingRunner(answer: "## Lokal")
        let cloud = RecordingRunner(answer: "## Cloud")
        let structurer = BraindumpStructurer(
            local: local, cloud: cloud,
            localModel: { nil },
            cloudAvailable: { true }
        )

        #expect(try await structurer.structure("Text") == "## Cloud")
        #expect(cloud.models == [ModelManager.cloudPlaceholderModelURL])
        #expect(local.models.isEmpty)
    }

    @Test("without any model the structurer says so")
    func noModel() async {
        let structurer = BraindumpStructurer(
            local: RecordingRunner(answer: ""), cloud: RecordingRunner(answer: ""),
            localModel: { nil },
            cloudAvailable: { false }
        )

        await #expect(throws: BraindumpError.noModel) {
            try await structurer.structure("Text")
        }
    }
}
