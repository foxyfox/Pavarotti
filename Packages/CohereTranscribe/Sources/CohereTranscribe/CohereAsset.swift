import Foundation

/// One downloadable file the local Cohere runtime needs, pinned by size and SHA-256.
///
/// Paths are relative to the asset root (see ``CohereLocations``), so the same layout
/// works for Pavarotti's own copy and for the TypeWhisper copy used as a seed.
public struct CohereAsset: Sendable, Hashable {
    /// How the downloaded file becomes installed files.
    public enum Kind: Sendable, Hashable {
        /// The download is the installed file, stored at ``CohereAsset/relativePath``.
        case file
        /// A `.tar.gz` unpacked into ``CohereAsset/relativePath``. The listed paths
        /// (relative to the asset root) must exist afterwards.
        case tarGzip(installedFiles: [String])
    }

    /// Short name for progress output and errors.
    public let name: String
    public let source: URL
    public let relativePath: String
    public let size: Int64
    /// Lowercase hex SHA-256 of the downloaded file.
    public let sha256: String
    public let kind: Kind

    public init(
        name: String,
        source: URL,
        relativePath: String,
        size: Int64,
        sha256: String,
        kind: Kind = .file
    ) {
        self.name = name
        self.source = source
        self.relativePath = relativePath
        self.size = size
        self.sha256 = sha256
        self.kind = kind
    }

    /// Files that must exist (non-empty) below the root once this asset is installed.
    public var installedFiles: [String] {
        switch kind {
        case .file: [relativePath]
        case let .tarGzip(installedFiles): installedFiles
        }
    }
}

/// The pinned files of the CrispASR runtime and its helper models.
///
/// Versions, revisions and checksums match what the TypeWhisper fork runs today, so an
/// existing TypeWhisper download can be reused byte for byte.
public enum CohereAssetCatalog {
    public static let crispASRVersion = "0.8.24"

    static let modelRepository = "cstr/cohere-transcribe-03-2026-GGUF"
    static let modelRevision = "2242638d5dfecc6f1dbe6c3a8713b97deb2e150f"

    /// The CrispASR command line runtime (server mode, Metal).
    public static let runtime = CohereAsset(
        name: "CrispASR \(crispASRVersion)",
        source: webURL(
            "https://github.com/CrispStrobe/CrispASR/releases/download/v\(crispASRVersion)/crispasr-macos.tar.gz"
        ),
        relativePath: "Runtime",
        size: 15_656_391,
        sha256: "78397afd5aef2dbd6fa73f8d60800dd4d5725589fb4b04800efd2fb3ff88930c",
        kind: .tarGzip(installedFiles: [runtimeExecutablePath, "Runtime/crispasr-macos/libc2pa_c.dylib"])
    )

    /// Silero voice activity detection, required by the server's VAD pipeline.
    public static let voiceActivityModel = CohereAsset(
        name: "Silero VAD",
        source: huggingFaceURL(
            repository: "ggml-org/whisper-vad",
            revision: "9ffd54a1e1ee413ddf265af9913beaf518d1639b",
            file: "ggml-silero-v6.2.0.bin"
        ),
        relativePath: "Auxiliary/ggml-silero-v6.2.0.bin",
        size: 885_098,
        sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"
    )

    /// Silero language identification. Cohere has no language ID of its own; this
    /// model lets the server tell German from English before transcribing.
    public static let languageIdentificationModel = CohereAsset(
        name: "Silero language ID",
        source: huggingFaceURL(
            repository: "cstr/silero-lid-lang95-GGUF",
            revision: "78fb93154156272b2448183dfbf62b648ece4e52",
            file: "silero-lid-lang95-f32.gguf"
        ),
        relativePath: "Auxiliary/silero-lid-lang95-f32.gguf",
        size: 16_900_416,
        sha256: "ed161165bb6fabae895f8837761b57bde50ede273ec83f6ad37ba982ce3e54da"
    )

    /// Canary CTC forced aligner. With it the server times every word from the audio
    /// instead of spreading the words evenly over a chunk, so meeting sentences can be
    /// matched to speakers. Optional: dictation works without it. Same pin as the
    /// TypeWhisper fork, stored under the same relative path as there so its copy is reused.
    public static let wordAligner = CohereAsset(
        name: "Canary CTC aligner",
        source: huggingFaceURL(
            repository: "cstr/canary-ctc-aligner-GGUF",
            revision: "2b22dc9aff585bc8368a5228173c8afe22c155b7",
            file: "canary-ctc-aligner-q4_k.gguf"
        ),
        relativePath: "MeetingModels/canary-ctc-aligner-q4_k.gguf",
        size: 392_167_040,
        sha256: "d16dbf18f9a66f59c0ceb61b204caca5dda21742d6e9dc304c9d0518c81ee38c"
    )

    static let runtimeExecutablePath = "Runtime/crispasr-macos/crispasr"

    /// Everything a model needs to run, the model itself first.
    public static func assets(for model: CohereModel) -> [CohereAsset] {
        [model.asset, voiceActivityModel, languageIdentificationModel, runtime]
    }

    static func modelAsset(file: String, size: Int64, sha256: String) -> CohereAsset {
        CohereAsset(
            name: file,
            source: huggingFaceURL(repository: modelRepository, revision: modelRevision, file: file),
            relativePath: file,
            size: size,
            sha256: sha256
        )
    }

    static func huggingFaceURL(repository: String, revision: String, file: String) -> URL {
        webURL("https://huggingface.co/\(repository)/resolve/\(revision)/\(file)")
    }

    private static func webURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid pinned asset URL: \(string)")
        }
        return url
    }
}
