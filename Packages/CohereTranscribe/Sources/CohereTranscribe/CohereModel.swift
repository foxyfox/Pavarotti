import Foundation

/// One speech model the local CrispASR runtime can serve.
///
/// Four quantizations of Cohere Transcribe 03-2026, plus NVIDIA's much smaller Parakeet
/// TDT 0.6B v3 for Macs with little memory. All run on Metal through CrispASR.
/// ``recommended`` (Cohere Q5_0) is the best tested balance of size, speed and accuracy.
public struct CohereModel: Sendable, Hashable, Identifiable {
    /// The CrispASR backend that runs a model.
    public enum Backend: String, Sendable, Hashable {
        /// Cohere Transcribe. It needs the language up front, which Silero detects, and
        /// gets exact word times from the separate aligner.
        case cohere
        /// NVIDIA Parakeet TDT. It detects the language and times the words itself.
        case parakeet

        /// Whether word times for meetings come from the separate aligner.
        public var usesWordAligner: Bool {
            self == .cohere
        }

        /// Whether the model finds the language on its own. Parakeet ignores the requested
        /// language and writes what it hears, so asking again in another language changes
        /// nothing, and the server's language ID is not needed.
        var detectsLanguage: Bool {
            self == .parakeet
        }
    }

    /// Stable ID, also sent to the server as the model name.
    public let id: String
    public let displayName: String
    public let asset: CohereAsset
    public let backend: Backend

    /// Parakeet TDT 0.6B v3: about a quarter of Cohere's size and much faster, for older
    /// Macs. Its German is likely a little less accurate than Cohere's.
    public static let small = CohereModel(
        id: "parakeet-tdt-0.6b-v3-q4_k",
        displayName: "Small (Parakeet 0.6B, for older Macs)",
        asset: CohereAssetCatalog.modelAsset(
            file: "parakeet-tdt-0.6b-v3-q4_k.gguf",
            size: 417_894_912,
            sha256: "addef407ab841eef45739e78920fd8c00e63f78eaa823c490e600e0ab58080a1",
            repository: CohereAssetCatalog.parakeetRepository,
            revision: CohereAssetCatalog.parakeetRevision
        ),
        backend: .parakeet
    )

    /// The repository's newer Q4_K, about 220 MB smaller than the one TypeWhisper used.
    public static let compact = CohereModel(
        id: "cohere-transcribe-03-2026-q4_k",
        displayName: "Compact (Cohere Q4_K)",
        asset: CohereAssetCatalog.modelAsset(
            file: "cohere-transcribe-q4_k.gguf",
            size: 1_289_178_240,
            sha256: "116f4c4f7ff1b03997100d3a097e13fecd84350555b9979867b241cd6803e4f5",
            revision: CohereAssetCatalog.compactRevision
        ),
        backend: .cohere
    )

    public static let fast = CohereModel(
        id: "cohere-transcribe-03-2026-q5_0",
        displayName: "Fast (Cohere Q5_0, recommended)",
        asset: CohereAssetCatalog.modelAsset(
            file: "cohere-transcribe-q5_0.gguf",
            size: 1_738_722_944,
            sha256: "a09696c5cc2ed5052bf290c4f2beb35abc69c0d6986842042d92bebb22c9184e"
        ),
        backend: .cohere
    )

    public static let precise = CohereModel(
        id: "cohere-transcribe-03-2026-q6_k",
        displayName: "Higher precision (Cohere Q6_K)",
        asset: CohereAssetCatalog.modelAsset(
            file: "cohere-transcribe-q6_k.gguf",
            size: 1_981_355_648,
            sha256: "0ad2634e0ba34efa38a47d4fd4cf34d7a2d738d8486d83b8d5a178f823109c52"
        ),
        backend: .cohere
    )

    public static let maximum = CohereModel(
        id: "cohere-transcribe-03-2026-q8_0",
        displayName: "Maximum precision (Cohere Q8_0, experimental)",
        asset: CohereAssetCatalog.modelAsset(
            file: "cohere-transcribe-q8_0.gguf",
            size: 2_423_803_520,
            sha256: "c8620cb182a7c04e311e6c24e478b94f7ecd7f1b5230bf39fffa8daf94644f51"
        ),
        backend: .cohere
    )

    public static let all: [CohereModel] = [small, compact, fast, precise, maximum]

    public static let recommended = fast

    /// Looks a model up by ``id``.
    public static func model(id: String) -> CohereModel? {
        all.first { $0.id == id }
    }
}
