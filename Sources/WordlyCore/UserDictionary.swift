import Foundation

public final class UserDictionary {
    public let url: URL
    private var cachedMtime: Date?
    private var cachedTerms: [String] = []

    public static let template = """
    # Wordly dictionary — one term per line (names, jargon).
    # Lines starting with # are ignored. Fed to Whisper to bias recognition.
    """

    public init(url: URL = Config.dir.appendingPathComponent("dictionary.txt")) {
        self.url = url
    }

    public func terms() -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? (Self.template + "\n").write(to: url, atomically: true, encoding: .utf8)
            cachedMtime = nil
            cachedTerms = []
            return []
        }
        let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if let mtime, mtime == cachedMtime { return cachedTerms }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        cachedTerms = content.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        cachedMtime = mtime
        return cachedTerms
    }

    public func initialPrompt() -> String {
        let t = terms()
        return t.isEmpty ? "" : "Glossary: \(t.joined(separator: ", "))."
    }
}
