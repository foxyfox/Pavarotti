// swift-tools-version: 6.0
// Strict concurrency is enabled by default with Swift 6 language mode.

import PackageDescription

let package = Package(
    name: "CohereTranscribe",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "CohereTranscribe", targets: ["CohereTranscribe"]),
        // Manual test harness for a real Mac, like transcribe-cli in Transcription.
        .executable(name: "cohere-cli", targets: ["cohere-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "CohereTranscribe",
            path: "Sources/CohereTranscribe",
            swiftSettings: warningsAsErrors
        ),
        .executableTarget(
            name: "cohere-cli",
            dependencies: [
                "CohereTranscribe",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/cohere-cli",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "CohereTranscribeTests",
            dependencies: ["CohereTranscribe"],
            path: "Tests/CohereTranscribeTests",
            swiftSettings: warningsAsErrors
        )
    ],
    swiftLanguageModes: [.v6]
)

/// Applied to every target so the whole package is held to the strict bar.
/// Uses the `-warnings-as-errors` flag rather than the 6.2-only `treatAllWarnings(as:)`
/// API so the manifest stays buildable on Swift 6.0+ toolchains. The `unsafeFlags`
/// dependency restriction doesn't apply: the app consumes CohereTranscribe as a local
/// path dependency, which is exempt.
let warningsAsErrors: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]
