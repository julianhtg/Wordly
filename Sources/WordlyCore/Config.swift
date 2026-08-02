import Foundation

public struct Config: Codable, Equatable {
    public var keyCode: Int64 = 10            // ^ on German ISO (kVK_ISO_Section)
    public var whisperModel: String = "large-v3-turbo"
    public var ollamaModel: String = "gemma3:4b"
    public var cleanupEnabled: Bool = false
    /// The languages the user speaks, most-used first. Empty = detect among all
    /// of them. One entry pins it — the fastest and most accurate path, since
    /// whisper then skips a whole encoder pass. Several = detect, but only ever
    /// choose from this list.
    public var languages: [String] = []
    /// "auto" picks Parakeet when it covers every selected language and Whisper
    /// otherwise; "parakeet" / "whisper" force one, which is how you A/B them.
    public var engine: String = "auto"
    public var showIndicator: Bool = true     // floating voice widget
    public var inputDeviceUID: String? = nil  // nil = system default microphone

    public init() {}

    /// Language to fall back to when detection is not confident.
    public var primaryLanguage: String { languages.first ?? "en" }

    private enum LegacyKeys: String, CodingKey {
        case language  // pre-1.2: a single "auto" | "de" | "en"
    }

    // Decode field-by-field so a config.json written by an older version
    // (missing keys) keeps its values and picks up defaults for new keys,
    // instead of failing to decode and resetting the whole file.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decodeIfPresent(Int64.self, forKey: .keyCode) ?? keyCode
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? whisperModel
        ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? ollamaModel
        cleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? cleanupEnabled
        if let list = try c.decodeIfPresent([String].self, forKey: .languages) {
            languages = list
        } else if let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(String.self, forKey: .language) {
            // pre-1.2 had one language and three choices, so "auto" was the
            // default rather than a decision — migrate it to the macOS language
            // order, which is both faster and more accurate than detecting
            // among 100. An explicit "de" stays exactly that.
            languages = legacy == "auto" ? Self.systemLanguages() : [legacy]
        }
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? engine
        showIndicator = try c.decodeIfPresent(Bool.self, forKey: .showIndicator) ?? showIndicator
        inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? inputDeviceUID
    }

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
        var config = Config()
        // Fresh install: start from the languages macOS is already set up for.
        // A pinned language is both the fastest and the most accurate path, and
        // "Auto — all languages" is one click away in the menu.
        config.languages = Self.systemLanguages()
        config.save(to: url)  // ponytail: corrupt file overwritten with defaults, no backup
        return config
    }

    /// The first two known languages from the user's macOS language order.
    /// Two, not all of them: every extra language past the first costs whisper
    /// an entire encoder pass to work out which one you spoke.
    static func systemLanguages(_ preferred: [String] = Locale.preferredLanguages) -> [String] {
        var codes: [String] = []
        for identifier in preferred {
            guard let code = Locale(identifier: identifier).language.languageCode?.identifier,
                  Languages.isKnown(code), !codes.contains(code) else { continue }
            codes.append(code)
        }
        return Array(codes.prefix(2))
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
