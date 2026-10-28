import CryptoKit
import Foundation
import Testing
@testable import CohereTranscribe

@Suite("Installer")
struct InstallerTests {
    let root: URL
    let seed: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "cohere-tests-\(UUID().uuidString)")
        root = base.appending(path: "root", directoryHint: .isDirectory)
        seed = base.appending(path: "seed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
    }

    @Test("A downloaded file is verified and moved into place")
    func installsDownload() async throws {
        let payload = Data("model weights".utf8)
        let asset = try makeAsset(named: "model.gguf", data: payload)
        let downloader = FakeDownloader(contents: [asset.source: payload])
        let installer = CohereInstaller(root: root, seedRoots: [seed], downloader: downloader)

        try await installer.install(assets: [asset])

        #expect(installer.isInstalled(asset))
        #expect(try Data(contentsOf: root.appending(path: "model.gguf")) == payload)
        #expect(downloader.log.count == 1)
    }

    @Test("Installed assets are not fetched again")
    func skipsInstalled() async throws {
        let payload = Data("vad".utf8)
        let asset = try makeAsset(named: "Auxiliary/vad.bin", data: payload)
        let downloader = FakeDownloader(contents: [asset.source: payload])
        let installer = CohereInstaller(root: root, seedRoots: [seed], downloader: downloader)

        try await installer.install(assets: [asset])
        try await installer.install(assets: [asset])

        #expect(downloader.log.count == 1)
    }

    @Test("A file with the wrong checksum is rejected and not installed")
    func rejectsChecksumMismatch() async throws {
        let payload = Data("tampered".utf8)
        let pinned = try makeAsset(named: "model.gguf", data: Data("original".utf8))
        let asset = CohereAsset(
            name: pinned.name,
            source: pinned.source,
            relativePath: pinned.relativePath,
            size: Int64(payload.count),
            sha256: pinned.sha256
        )
        let installer = CohereInstaller(
            root: root,
            seedRoots: [seed],
            downloader: FakeDownloader(contents: [asset.source: payload])
        )

        await #expect(throws: CohereError.checksumMismatch(asset: "model.gguf")) {
            try await installer.install(assets: [asset])
        }
        #expect(!installer.isInstalled(asset))
    }

    @Test("A seed copy with the right size is used instead of a download")
    func usesSeed() async throws {
        let payload = Data("already downloaded by TypeWhisper".utf8)
        let asset = try makeAsset(named: "model.gguf", data: payload)
        try payload.write(to: seed.appending(path: "model.gguf"))
        let downloader = FakeDownloader(contents: [:])
        let installer = CohereInstaller(root: root, seedRoots: [seed], downloader: downloader)

        try await installer.install(assets: [asset])

        #expect(installer.isInstalled(asset))
        #expect(downloader.log.isEmpty)
    }

    @Test("A seed copy counts as available and is left out of the download size")
    func seedCopyIsNotDownloaded() throws {
        let installer = CohereInstaller(root: root, seedRoots: [seed], downloader: FakeDownloader(contents: [:]))
        let model = CohereModel.recommended
        let total = CohereAssetCatalog.assets(for: model).reduce(Int64(0)) { $0 + $1.size }
        #expect(!installer.hasSeedCopy(of: model.asset))
        #expect(installer.downloadSize(for: model) == total)

        let copy = seed.appending(path: model.asset.relativePath)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: copy.path, contents: nil))
        let handle = try FileHandle(forWritingTo: copy)
        try handle.truncate(atOffset: UInt64(model.asset.size))
        try handle.close()

        #expect(installer.hasSeedCopy(of: model.asset))
        #expect(installer.downloadSize(for: model) == total - model.asset.size)
    }

    @Test("A seed copy with another size is ignored")
    func ignoresWrongSizeSeed() async throws {
        let payload = Data("current model".utf8)
        let asset = try makeAsset(named: "model.gguf", data: payload)
        try Data("older, shorter".utf8).write(to: seed.appending(path: "model.gguf"))
        let downloader = FakeDownloader(contents: [asset.source: payload])
        let installer = CohereInstaller(root: root, seedRoots: [seed], downloader: downloader)

        try await installer.install(assets: [asset])

        #expect(downloader.log.count == 1)
        #expect(try Data(contentsOf: root.appending(path: "model.gguf")) == payload)
    }

    @Test("Download failures are reported per asset")
    func reportsDownloadFailure() async throws {
        let asset = try makeAsset(named: "model.gguf", data: Data("x".utf8))
        let installer = CohereInstaller(root: root, seedRoots: [seed], downloader: FakeDownloader(contents: [:]))

        await #expect(throws: CohereError.self) {
            try await installer.install(assets: [asset])
        }
    }

    @Test("A tar.gz runtime is unpacked below its directory")
    func extractsArchive() async throws {
        let archive = try makeRuntimeArchive()
        let asset = try CohereAsset(
            name: "runtime",
            source: #require(URL(string: "https://example.com/runtime.tar.gz")),
            relativePath: "Runtime",
            size: Int64(archive.count),
            sha256: sha256(archive),
            kind: .tarGzip(installedFiles: ["Runtime/crispasr-macos/crispasr"])
        )
        let installer = CohereInstaller(
            root: root,
            seedRoots: [seed],
            downloader: FakeDownloader(contents: [asset.source: archive])
        )

        try await installer.install(assets: [asset])

        #expect(installer.isInstalled(asset))
    }

    @Test("Progress ends at the total size of what was fetched")
    func progressReachesTotal() async throws {
        let first = Data("first".utf8)
        let second = Data("second file".utf8)
        let assets = try [makeAsset(named: "a.bin", data: first), makeAsset(named: "b.bin", data: second)]
        let downloader = FakeDownloader(contents: [assets[0].source: first, assets[1].source: second])
        let installer = CohereInstaller(root: root, seedRoots: [seed], downloader: downloader)
        let updates = Recorder<CohereInstallProgress>()

        try await installer.install(assets: assets) { updates.record($0) }

        let last = try #require(updates.values.last)
        #expect(last.totalBytes == Int64(first.count + second.count))
        #expect(last.completedBytes == last.totalBytes)
    }

    // MARK: - Helpers

    private func makeAsset(named path: String, data: Data) throws -> CohereAsset {
        try CohereAsset(
            name: URL(fileURLWithPath: path).lastPathComponent,
            source: #require(URL(string: "https://example.com/\(path)")),
            relativePath: path,
            size: Int64(data.count),
            sha256: sha256(data)
        )
    }

    private func makeRuntimeArchive() throws -> Data {
        let staging = seed.appending(path: "archive", directoryHint: .isDirectory)
        let folder = staging.appending(path: "crispasr-macos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: folder.appending(path: "crispasr"))
        let archive = seed.appending(path: "runtime.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", archive.path, "-C", staging.path, "crispasr-macos"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try Data(contentsOf: archive)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@Suite("Asset catalog")
struct AssetCatalogTests {
    @Test("Every model pins a size and a SHA-256")
    func modelsArePinned() {
        for model in CohereModel.all {
            #expect(model.asset.size > 0)
            #expect(model.asset.sha256.count == 64)
            #expect(model.asset.source.absoluteString.contains(model.asset.relativePath))
        }
        #expect(Set(CohereModel.all.map(\.id)).count == CohereModel.all.count)
    }

    @Test("A model needs itself, VAD, language ID and the runtime")
    func assetsForModel() {
        let assets = CohereAssetCatalog.assets(for: .recommended)
        #expect(assets.map(\.name) == [
            CohereModel.fast.asset.name,
            CohereAssetCatalog.voiceActivityModel.name,
            CohereAssetCatalog.languageIdentificationModel.name,
            CohereAssetCatalog.runtime.name
        ])
    }

    @Test("Parakeet needs no language ID")
    func assetsForParakeet() {
        #expect(CohereAssetCatalog.assets(for: .small).map(\.name) == [
            CohereModel.small.asset.name,
            CohereAssetCatalog.voiceActivityModel.name,
            CohereAssetCatalog.runtime.name
        ])
    }

    @Test("Only Cohere models use the word aligner and the language ID")
    func backends() {
        #expect(CohereModel.small.backend == .parakeet)
        #expect(!CohereModel.small.backend.usesWordAligner)
        #expect(CohereModel.small.backend.detectsLanguage)
        for model in CohereModel.all where model != .small {
            #expect(model.backend == .cohere)
            #expect(model.backend.usesWordAligner)
            #expect(!model.backend.detectsLanguage)
        }
    }

    @Test("The small and compact models come from their own pinned revisions")
    func pinnedRevisions() {
        let small = CohereModel.small.asset.source.absoluteString
        #expect(small.contains(CohereAssetCatalog.parakeetRepository))
        #expect(small.contains(CohereAssetCatalog.parakeetRevision))
        #expect(CohereModel.compact.asset.source.absoluteString.contains(CohereAssetCatalog.compactRevision))
        #expect(CohereModel.fast.asset.source.absoluteString.contains(CohereAssetCatalog.modelRevision))
        #expect(CohereModel.recommended == .fast)
    }

    @Test("The word aligner is pinned and optional")
    func wordAligner() {
        let aligner = CohereAssetCatalog.wordAligner
        #expect(aligner.size == 392_167_040)
        #expect(aligner.sha256.count == 64)
        #expect(aligner.source.absoluteString.hasSuffix("canary-ctc-aligner-q4_k.gguf"))
        for model in CohereModel.all {
            #expect(!CohereAssetCatalog.assets(for: model).contains(aligner))
        }
    }

    @Test("Models are found by ID")
    func lookup() {
        #expect(CohereModel.model(id: "cohere-transcribe-03-2026-q5_0") == .fast)
        #expect(CohereModel.model(id: "nope") == nil)
    }
}

/// Serves fixed data per URL and records every download.
struct FakeDownloader: FileDownloading {
    let contents: [URL: Data]
    let log = Recorder<URL>()

    func download(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        log.record(source)
        guard let data = contents[source] else {
            throw URLError(.fileDoesNotExist)
        }
        try data.write(to: destination)
        progress(Int64(data.count))
    }
}

/// Thread-safe list of values recorded from `@Sendable` callbacks.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    var count: Int {
        values.count
    }

    var isEmpty: Bool {
        values.isEmpty
    }

    func record(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}
