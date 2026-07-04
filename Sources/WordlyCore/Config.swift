import Foundation

public struct Config: Codable, Equatable {
    public var keyCode: Int64 = 10            // ^ on German ISO (kVK_ISO_Section)
    public var whisperModel: String = "large-v3-turbo"
    public var ollamaModel: String = "gemma3:4b"
    public var cleanupEnabled: Bool = false
    public var language: String = "auto"      // "auto" | "de" | "en"

    public init() {}

    public static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/wordly", isDirectory: true)
    public static let fileURL = dir.appendingPathComponent("config.json")

    public var modelURL: URL {
        Self.dir.appendingPathComponent("models/ggml-\(whisperModel).bin")
    }

    public static func load(from url: URL = fileURL) -> Config {
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            return config
        }
        let config = Config()
        config.save(to: url)  // ponytail: corrupt file overwritten with defaults, no backup
        return config
    }

    public func save(to url: URL = fileURL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
