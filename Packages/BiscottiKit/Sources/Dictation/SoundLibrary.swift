import Foundation

/// The sounds dictation can play: macOS system sounds and the user's own files.
///
/// Pavarotti ships no sound files. Users add their own (for example the ones they used
/// in TypeWhisper), which are copied into `Application Support/Pavarotti/Sounds`.
public struct SoundLibrary: Sendable {
    public let directory: URL

    public static let systemSoundsDirectory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)

    /// The sounds every Mac has.
    public static let systemSoundNames = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    static let fileExtensions: Set<String> = ["wav", "aiff", "aif", "mp3", "m4a", "caf"]

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Pavarotti/Sounds`.
    public static var standard: SoundLibrary {
        SoundLibrary(directory: URL.applicationSupportDirectory.appending(path: "Pavarotti/Sounds", directoryHint: .isDirectory))
    }

    /// File names of the user's sounds, sorted.
    public func customSoundNames() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents
            .filter { Self.fileExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The file to play for `choice`, if it exists.
    public func url(for choice: SoundChoice) -> URL? {
        let url: URL
        switch choice {
        case .none:
            return nil
        case let .system(name):
            url = Self.systemSoundsDirectory.appending(path: "\(name).aiff")
        case let .file(name):
            url = directory.appending(path: name)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies an audio file into the library and returns its file name there.
    /// A file with the same name is replaced.
    @discardableResult
    public func importSound(from source: URL, as name: String? = nil) throws -> String {
        let fileName = name ?? source.lastPathComponent
        guard Self.fileExtensions.contains(URL(fileURLWithPath: fileName).pathExtension.lowercased()) else {
            throw DictationError.unsupportedSoundFile(fileName)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        return fileName
    }
}
