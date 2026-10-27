import ArgumentParser
import CohereTranscribe
import Foundation

@main
struct CohereCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cohere-cli",
        abstract: "Install and try local Cohere Transcribe (CrispASR) on this Mac.",
        discussion: """
        Files live in ~/Library/Application Support/Pavarotti/Models. An existing
        TypeWhisper download is copied instead of downloaded again.
        """,
        subcommands: [Status.self, Install.self, Transcribe.self],
        defaultSubcommand: Status.self
    )
}

/// Options shared by all subcommands.
struct ModelOptions: ParsableArguments {
    @Option(help: "Model ID. One of: \(CohereModel.all.map(\.id).joined(separator: ", "))")
    var model = CohereModel.recommended.id

    func resolvedModel() throws -> CohereModel {
        guard let resolved = CohereModel.model(id: model) else {
            throw ValidationError("Unknown model \(model)")
        }
        return resolved
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what is installed.")

    @OptionGroup var options: ModelOptions

    func run() async throws {
        let model = try options.resolvedModel()
        let installer = CohereInstaller()
        print("Root: \(installer.root.path)")
        for asset in CohereAssetCatalog.assets(for: model) {
            let mark = installer.isInstalled(asset) ? "installed" : "missing"
            print("\(mark)\t\(asset.name)")
        }
    }
}

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Download or copy the runtime and model.")

    @OptionGroup var options: ModelOptions

    func run() async throws {
        let model = try options.resolvedModel()
        let installer = CohereInstaller()
        let missing = installer.missingAssets(for: model)
        guard !missing.isEmpty else {
            print("Everything is installed.")
            return
        }
        print("Installing \(missing.map(\.name).joined(separator: ", "))")
        let reporter = ProgressReporter()
        try await installer.install(model: model) { progress in
            reporter.report(progress)
        }
        print("\nDone.")
    }
}

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe an audio file.")

    @OptionGroup var options: ModelOptions

    @Option(help: "auto, de or en")
    var language = TranscriptionLanguage.automatic.rawValue

    @Flag(help: "Print segments with timestamps.")
    var segments = false

    @Argument(help: "Audio file (WAV, MP3, M4A, FLAC, OGG).")
    var file: String

    func run() async throws {
        guard let requested = TranscriptionLanguage(rawValue: language) else {
            throw ValidationError("Language must be auto, de or en")
        }
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        let transcriber = try CohereTranscriber(model: options.resolvedModel())

        let warmStart = ContinuousClock.now
        try await transcriber.warmUp()
        log("Server ready after \(ContinuousClock.now - warmStart)")

        let start = ContinuousClock.now
        let result = try await transcriber.transcribe(fileURL: url, language: requested)
        log("Transcribed in \(ContinuousClock.now - start), language \(result.language)")

        if segments {
            for segment in result.segments {
                print(String(format: "[%7.2f – %7.2f] ", segment.start, segment.end) + segment.text)
            }
        } else {
            print(result.text)
        }
        await transcriber.shutdown()
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

/// Prints install progress on one line, at most once per percent.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1

    func report(_ progress: CohereInstallProgress) {
        let percent = Int(progress.fraction * 100)
        let shouldPrint = lock.withLock {
            guard percent != lastPercent else { return false }
            lastPercent = percent
            return true
        }
        guard shouldPrint else { return }
        let line = "\r\(percent)% \(progress.assetName)                    "
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}
