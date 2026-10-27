import Foundation

/// Where the Cohere runtime and models live on disk.
public enum CohereLocations {
    /// Directory name below `Models/`, the same as in the TypeWhisper plugin.
    static let assetDirectoryName = "cohere-transcribe-03-2026"

    /// Pavarotti's own copy: `~/Library/Application Support/Pavarotti/Models/cohere-transcribe-03-2026`.
    public static var defaultRoot: URL {
        applicationSupport
            .appending(path: "Pavarotti/Models", directoryHint: .isDirectory)
            .appending(path: assetDirectoryName, directoryHint: .isDirectory)
    }

    /// Existing TypeWhisper downloads that can be copied instead of downloaded again.
    /// The second entry is the plugin's older directory name, the third the fork's own
    /// data directory, which holds the word aligner under `MeetingModels/`.
    public static var typeWhisperSeedRoots: [URL] {
        let models = applicationSupport.appending(
            path: "TypeWhisper/PluginData/com.typewhisper.cohere-transcribe/Models",
            directoryHint: .isDirectory
        )
        return [
            models.appending(path: assetDirectoryName, directoryHint: .isDirectory),
            models.appending(path: "\(assetDirectoryName)-q5_0", directoryHint: .isDirectory),
            applicationSupport.appending(path: "TypeWhisper", directoryHint: .isDirectory)
        ]
    }

    private static var applicationSupport: URL {
        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return url
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
    }
}
