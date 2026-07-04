// swift-tools-version:6.0
import PackageDescription

let swift5 = [SwiftSetting.swiftLanguageMode(.v5)]

let package = Package(
    name: "Wordly",
    platforms: [.macOS("13.3")],
    targets: [
        .binaryTarget(name: "whisper", path: "vendor/whisper.xcframework"),
        .target(name: "WordlyCore", dependencies: ["whisper"], swiftSettings: swift5),
        .executableTarget(name: "Wordly", dependencies: ["WordlyCore"], swiftSettings: swift5),
        .testTarget(name: "WordlyCoreTests", dependencies: ["WordlyCore"], swiftSettings: swift5),
    ]
)
