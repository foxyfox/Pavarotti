import Foundation

/// Progress of an install, summed over all assets that still had to be fetched.
public struct CohereInstallProgress: Sendable, Equatable {
    /// The asset currently being fetched or verified.
    public let assetName: String
    public let completedBytes: Int64
    public let totalBytes: Int64

    public var fraction: Double {
        totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1
    }
}

/// Installs the Cohere runtime and a model below one root directory.
///
/// Each missing asset is copied from a seed directory (an existing TypeWhisper
/// download) when one holds a file of the right size, and downloaded otherwise.
/// Every file is checked against its pinned SHA-256 before it is moved into place,
/// so a half-written or tampered file never counts as installed.
public struct CohereInstaller: Sendable {
    public let root: URL
    public let seedRoots: [URL]
    private let downloader: any FileDownloading

    public init(
        root: URL = CohereLocations.defaultRoot,
        seedRoots: [URL] = CohereLocations.typeWhisperSeedRoots,
        downloader: any FileDownloading = URLSessionFileDownloader()
    ) {
        self.root = root
        self.seedRoots = seedRoots
        self.downloader = downloader
    }

    /// Whether every installed file of `asset` exists below the root and is non-empty.
    /// Plain files must also have their pinned size.
    public func isInstalled(_ asset: CohereAsset) -> Bool {
        switch asset.kind {
        case .file:
            fileSize(at: root.appending(path: asset.relativePath)) == asset.size
        case .tarGzip:
            asset.installedFiles.allSatisfy { (fileSize(at: root.appending(path: $0)) ?? 0) > 0 }
        }
    }

    /// The assets of `model` that still need to be installed.
    public func missingAssets(for model: CohereModel) -> [CohereAsset] {
        CohereAssetCatalog.assets(for: model).filter { !isInstalled($0) }
    }

    /// Whether a seed directory holds a copy of `asset` that installing would use instead of
    /// a download.
    public func hasSeedCopy(of asset: CohereAsset) -> Bool {
        seedFile(for: asset) != nil
    }

    /// The bytes installing `model` still downloads: missing assets without a seed copy.
    public func downloadSize(for model: CohereModel) -> Int64 {
        missingAssets(for: model)
            .filter { !hasSeedCopy(of: $0) }
            .reduce(Int64(0)) { $0 + $1.size }
    }

    /// Installs everything `model` needs. Already installed assets are skipped.
    public func install(
        model: CohereModel,
        progress: @escaping @Sendable (CohereInstallProgress) -> Void = { _ in }
    ) async throws {
        try await install(assets: CohereAssetCatalog.assets(for: model), progress: progress)
    }

    /// Installs the given assets. Already installed ones are skipped.
    public func install(
        assets: [CohereAsset],
        progress: @escaping @Sendable (CohereInstallProgress) -> Void = { _ in }
    ) async throws {
        let missing = assets.filter { !isInstalled($0) }
        let totalBytes = missing.reduce(Int64(0)) { $0 + $1.size }
        var completedBytes = Int64(0)
        let staging = root.appending(path: ".staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        for asset in missing {
            try Task.checkCancellation()
            let alreadyDone = completedBytes
            let fetched = try await fetch(asset, into: staging) { bytes in
                let update = CohereInstallProgress(
                    assetName: asset.name,
                    completedBytes: alreadyDone + min(bytes, asset.size),
                    totalBytes: totalBytes
                )
                progress(update)
            }
            try verify(fetched, against: asset)
            try place(fetched, as: asset)
            completedBytes += asset.size
            let update = CohereInstallProgress(
                assetName: asset.name,
                completedBytes: completedBytes,
                totalBytes: totalBytes
            )
            progress(update)
        }
    }

    // MARK: - Steps

    /// Copies the asset from a seed root or downloads it into `staging`.
    private func fetch(
        _ asset: CohereAsset,
        into staging: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        let target = staging.appending(path: asset.source.lastPathComponent)
        if let seed = seedFile(for: asset) {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            // On APFS this is a clone, so even a 2 GB model copies instantly.
            try FileManager.default.copyItem(at: seed, to: target)
            progress(asset.size)
            return target
        }
        do {
            try await downloader.download(from: asset.source, to: target, progress: progress)
        } catch let error as CohereError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CohereError.downloadFailed(asset: asset.name, reason: error.localizedDescription)
        }
        return target
    }

    /// A seed copy of a plain-file asset with the pinned size, if any.
    private func seedFile(for asset: CohereAsset) -> URL? {
        guard case .file = asset.kind else { return nil }
        return seedRoots
            .map { $0.appending(path: asset.relativePath) }
            .first { fileSize(at: $0) == asset.size }
    }

    private func verify(_ file: URL, against asset: CohereAsset) throws {
        guard fileSize(at: file) == asset.size,
              try FileDigest.sha256Hex(of: file) == asset.sha256
        else {
            throw CohereError.checksumMismatch(asset: asset.name)
        }
    }

    private func place(_ file: URL, as asset: CohereAsset) throws {
        let fileManager = FileManager.default
        let destination = root.appending(path: asset.relativePath)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        switch asset.kind {
        case .file:
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: file, to: destination)
        case .tarGzip:
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            try TarArchive.extract(file, into: destination, assetName: asset.name)
            guard isInstalled(asset) else {
                throw CohereError.notInstalled(missing: asset.installedFiles)
            }
        }
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return nil
        }
        return size.int64Value
    }
}

/// Unpacks `.tar.gz` archives with the system `tar`.
enum TarArchive {
    static func extract(_ archive: URL, into directory: URL, assetName: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CohereError.extractionFailed(asset: assetName, status: process.terminationStatus)
        }
    }
}
