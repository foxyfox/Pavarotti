import Foundation

/// One quantization of Cohere Transcribe 03-2026 from the GGUF repository.
///
/// All four run on Metal through CrispASR. ``recommended`` (Q5_0) is the best tested
/// balance of size, speed and accuracy.
public struct CohereModel: Sendable, Hashable, Identifiable {
    /// Stable ID, also sent to the server as the model name.
    public let id: String
    public let displayName: String
    public let asset: CohereAsset

    public static let compact = CohereModel(
        id: "cohere-transcribe-03-2026-q4_k",
        displayName: "Compact (Q4_K)",
        asset: CohereAssetCatalog.modelAsset(
            file: "cohere-transcribe-q4_k.gguf",
            size: 1_510_362_752,
            sha256: "2931fc0ac6d6708eef5389aadf1ebd5eec7b8e764bac385be585e910c0e7b410"
        )
    )

    public static let fast = CohereModel(
        id: "cohere-transcribe-03-2026-q5_0",
        displayName: "Fast (Q5_0, recommended)",
        asset: CohereAssetCatalog.modelAsset(
            file: "cohere-transcribe-q5_0.gguf",
            size: 1_738_722_944,
            sha256: "a09696c5cc2ed5052bf290c4f2beb35abc69c0d6986842042d92bebb22c9184e"
        )
    )

    public static let precise = CohereModel(
        id: "cohere-transcribe-03-2026-q6_k",
        displayName: "Higher precision (Q6_K)",
        asset: CohereAssetCatalog.modelAsset(
            file: "cohere-transcribe-q6_k.gguf",
            size: 1_981_355_648,
            sha256: "0ad2634e0ba34efa38a47d4fd4cf34d7a2d738d8486d83b8d5a178f823109c52"
        )
    )

    public static let maximum = CohereModel(
        id: "cohere-transcribe-03-2026-q8_0",
        displayName: "Maximum precision (Q8_0, experimental)",
        asset: CohereAssetCatalog.modelAsset(
            file: "cohere-transcribe-q8_0.gguf",
            size: 2_423_803_520,
            sha256: "c8620cb182a7c04e311e6c24e478b94f7ecd7f1b5230bf39fffa8daf94644f51"
        )
    )

    public static let all: [CohereModel] = [compact, fast, precise, maximum]

    public static let recommended = fast

    /// Looks a model up by ``id``.
    public static func model(id: String) -> CohereModel? {
        all.first { $0.id == id }
    }
}
