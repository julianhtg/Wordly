// swift-tools-version:6.0
import PackageDescription

let swift5 = [SwiftSetting.swiftLanguageMode(.v5)]

let package = Package(
    name: "Wordly",
    // macOS 14 is FluidAudio's floor (whisper.cpp alone would run on 13.3).
    platforms: [.macOS(.v14)],
    dependencies: [
        // Parakeet TDT v3 on the Neural Engine: 25 European languages with
        // built-in language ID, orders of magnitude faster than Whisper's
        // encoder. Apache 2.0; the model weights are CC-BY-4.0 (see README).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        .binaryTarget(name: "whisper", path: "vendor/whisper.xcframework"),
        .target(name: "WordlyCore", dependencies: ["whisper", "FluidAudio"],
                swiftSettings: swift5),
        .executableTarget(name: "Wordly", dependencies: ["WordlyCore"], swiftSettings: swift5),
        // Latency/accuracy harness. Not part of the app bundle:
        // swift run -c release WordlyBench bench/audio
        .executableTarget(name: "WordlyBench", dependencies: ["WordlyCore"], swiftSettings: swift5),
        .testTarget(name: "WordlyCoreTests", dependencies: ["WordlyCore"], swiftSettings: swift5),
    ]
)
