import Foundation
import Testing
@testable import CohereTranscribe

@Suite("Server request and response")
struct RequestAndResponseTests {
    @Test("Multipart body carries the file and all form fields")
    func multipartBody() throws {
        let request = TranscriptionRequest(
            audio: Data("AUDIO".utf8),
            filename: "dictation.wav",
            model: "cohere-transcribe-03-2026-q5_0",
            language: "auto",
            boundary: "BOUNDARY"
        )
        let body = try #require(String(data: request.body, encoding: .utf8))
        #expect(body.hasPrefix("--BOUNDARY\r\n"))
        #expect(body.contains("name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\nAUDIO\r\n"))
        #expect(body.contains("name=\"model\"\r\n\r\ncohere-transcribe-03-2026-q5_0\r\n"))
        #expect(body.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        #expect(body.contains("name=\"language\"\r\n\r\nauto\r\n"))
        #expect(body.hasSuffix("--BOUNDARY--\r\n"))
        #expect(request.contentType == "multipart/form-data; boundary=BOUNDARY")
    }

    @Test("Language ID is turned off only for models that detect the language")
    func languageIdentificationField() throws {
        let plain = TranscriptionRequest(audio: Data(), filename: "a.wav", model: "m", language: "auto")
        #expect(!plain.formFields.contains { $0.0 == "lid_backend" })
        let parakeet = TranscriptionRequest(
            audio: Data(),
            filename: "a.wav",
            model: "m",
            language: "auto",
            skipsLanguageIdentification: true,
            boundary: "BOUNDARY"
        )
        let body = try #require(String(data: parakeet.body, encoding: .utf8))
        #expect(body.contains("name=\"lid_backend\"\r\n\r\noff\r\n"))
    }

    @Test("URL request targets the transcription endpoint with the API key")
    func urlRequest() throws {
        let endpoint = try LoopbackPort.url(port: 8123)
        let request = TranscriptionRequest(audio: Data(), filename: "a.mp3", model: "m", language: "de")
            .urlRequest(endpoint: endpoint, apiKey: "secret")
        #expect(request.url?.absoluteString == "http://127.0.0.1:8123/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test("MIME types follow the file extension")
    func mimeTypes() {
        #expect(TranscriptionRequest.mimeType(for: "a.WAV") == "audio/wav")
        #expect(TranscriptionRequest.mimeType(for: "a.m4a") == "audio/mp4")
        #expect(TranscriptionRequest.mimeType(for: "a.xyz") == "application/octet-stream")
    }

    @Test("verbose_json with segments decodes")
    func decodesVerboseJSON() throws {
        let json = """
        {"text":" Hallo Welt","language":"de","segments":[{"id":0,"start":0.0,"end":1.5,"text":" Hallo Welt"}]}
        """
        let decoded = try ServerTranscription.decode(Data(json.utf8))
        #expect(decoded.text == " Hallo Welt")
        #expect(decoded.language == "de")
        #expect(decoded.segments?.first?.end == 1.5)
    }

    @Test("Word times in verbose_json segments decode")
    func decodesWords() throws {
        let json = """
        {"text":"Hallo Welt.","language":"de","segments":[{"id":0,"start":0.48,"end":1.6,"text":"Hallo Welt.",\
        "words":[{"word":"Hallo","start":0.48,"end":0.56},{"word":"Welt.","start":0.88,"end":1.6}]}]}
        """
        let decoded = try ServerTranscription.decode(Data(json.utf8))
        let words = try #require(decoded.segments?.first?.words)
        #expect(words == [
            ServerTranscription.Word(word: "Hallo", start: 0.48, end: 0.56),
            ServerTranscription.Word(word: "Welt.", start: 0.88, end: 1.6)
        ])
    }

    @Test("Plain text answers without language or segments decode")
    func decodesMinimalJSON() throws {
        let decoded = try ServerTranscription.decode(Data(#"{"text":"Hi"}"#.utf8))
        #expect(decoded.text == "Hi")
        #expect(decoded.language == nil)
        #expect(decoded.segments == nil)
    }

    @Test("Garbage is reported as an invalid response")
    func rejectsGarbage() {
        #expect(throws: CohereError.invalidResponse) {
            try ServerTranscription.decode(Data("not json".utf8))
        }
    }

    @Test("Server arguments include language ID only when installed")
    func serverArguments() {
        let root = URL(fileURLWithPath: "/tmp/cohere")
        let withLID = CrispASRServer.Configuration(
            executable: root.appending(path: "crispasr"),
            model: root.appending(path: "model.gguf"),
            modelID: "m",
            voiceActivityModel: root.appending(path: "vad.bin"),
            languageIdentificationModel: root.appending(path: "lid.gguf"),
            cacheDirectory: root,
            threads: 4
        )
        let arguments = withLID.arguments(port: 9000)
        #expect(arguments.starts(with: ["--server", "--backend", "cohere", "--model", "/tmp/cohere/model.gguf"]))
        #expect(arguments.contains("9000"))
        #expect(Array(arguments.suffix(4)) == ["--lid-backend", "silero", "--lid-model", "/tmp/cohere/lid.gguf"])

        let withoutLID = CrispASRServer.Configuration(
            executable: root.appending(path: "crispasr"),
            model: root.appending(path: "model.gguf"),
            modelID: "m",
            voiceActivityModel: root.appending(path: "vad.bin"),
            languageIdentificationModel: nil,
            cacheDirectory: root
        )
        #expect(!withoutLID.arguments(port: 9000).contains("--lid-backend"))
        #expect(!withoutLID.arguments(port: 9000).contains("--aligner-model"))
    }

    @Test("Server arguments force the word aligner when it is installed")
    func alignerArguments() throws {
        let root = URL(fileURLWithPath: "/tmp/cohere")
        let configuration = CrispASRServer.Configuration(
            executable: root.appending(path: "crispasr"),
            model: root.appending(path: "model.gguf"),
            modelID: "m",
            voiceActivityModel: root.appending(path: "vad.bin"),
            languageIdentificationModel: root.appending(path: "lid.gguf"),
            wordAligner: root.appending(path: "aligner.gguf"),
            cacheDirectory: root
        )
        let arguments = configuration.arguments(port: 9000)
        let index = try #require(arguments.firstIndex(of: "--aligner-model"))
        #expect(Array(arguments[index ... index + 2]) == ["--aligner-model", "/tmp/cohere/aligner.gguf", "--force-aligner"])
        #expect(Array(arguments.suffix(4)) == ["--lid-backend", "silero", "--lid-model", "/tmp/cohere/lid.gguf"])
    }

    @Test("Server arguments name the model's backend")
    func parakeetArguments() {
        let root = URL(fileURLWithPath: "/tmp/cohere")
        let configuration = CrispASRServer.Configuration(
            executable: root.appending(path: "crispasr"),
            model: root.appending(path: "parakeet.gguf"),
            modelID: "p",
            backend: .parakeet,
            voiceActivityModel: root.appending(path: "vad.bin"),
            languageIdentificationModel: nil,
            cacheDirectory: root
        )
        let arguments = configuration.arguments(port: 9000)
        #expect(arguments.starts(with: ["--server", "--backend", "parakeet", "--model", "/tmp/cohere/parakeet.gguf"]))
        #expect(!arguments.contains("--lid-backend"))
        #expect(!arguments.contains("--aligner-model"))
    }

    @Test("A free loopback port can be reserved")
    func reservesPort() throws {
        let port = try LoopbackPort.reserve()
        #expect(port > 0)
    }
}
