import Foundation

/// A finished transcription.
public struct CohereTranscription: Sendable, Equatable {
    /// One word with its time range in seconds. With the word aligner installed the start
    /// is measured from the audio and the end lies about one aligner frame (80 ms) later,
    /// or over the following pause for words that end a sentence.
    public struct Word: Sendable, Equatable {
        public let text: String
        public let start: Double
        public let end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// One stretch of speech with its time range in seconds.
    public struct Segment: Sendable, Equatable {
        public let start: Double
        public let end: Double
        public let text: String
        /// The segment's words, empty when the server sent none.
        public let words: [Word]

        public init(start: Double, end: Double, text: String, words: [Word] = []) {
            self.start = start
            self.end = end
            self.text = text
            self.words = words
        }
    }

    public let text: String
    /// ISO 639-1 code of the language the text is in.
    public let language: String
    public let segments: [Segment]

    public init(text: String, language: String, segments: [Segment]) {
        self.text = text
        self.language = language
        self.segments = segments
    }
}

/// The server's OpenAI-compatible `verbose_json` answer.
struct ServerTranscription: Decodable, Equatable {
    struct Word: Decodable, Equatable {
        let word: String
        let start: Double
        let end: Double
    }

    struct Segment: Decodable, Equatable {
        let start: Double
        let end: Double
        let text: String
        let words: [Word]?
    }

    let text: String
    let language: String?
    let segments: [Segment]?

    static func decode(_ data: Data) throws -> ServerTranscription {
        do {
            return try JSONDecoder().decode(ServerTranscription.self, from: data)
        } catch {
            throw CohereError.invalidResponse
        }
    }
}

/// An upload to `POST /v1/audio/transcriptions` as `multipart/form-data`.
struct TranscriptionRequest {
    let audio: Data
    let filename: String
    let model: String
    let language: String
    /// Turns the server's language ID off for this request, for a model that detects the
    /// language itself. Otherwise "auto" could make the server fetch a Whisper model to
    /// detect it.
    var skipsLanguageIdentification = false
    var boundary = "pavarotti-\(UUID().uuidString)"

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    var body: Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(Self.mimeType(for: filename))\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n".utf8))
        for (name, value) in formFields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    var formFields: [(String, String)] {
        var fields = [("model", model), ("response_format", "verbose_json"), ("language", language)]
        if skipsLanguageIdentification {
            fields.append(("lid_backend", "off"))
        }
        return fields
    }

    func urlRequest(endpoint: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint.appending(path: "v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    static func mimeType(for filename: String) -> String {
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "m4a", "mp4": "audio/mp4"
        case "flac": "audio/flac"
        case "ogg": "audio/ogg"
        default: "application/octet-stream"
        }
    }
}
