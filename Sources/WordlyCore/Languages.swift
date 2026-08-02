import Foundation
import whisper

/// The languages the model actually knows, read out of whisper's own table so
/// the menu can never drift from what the model supports.
public enum Languages {
    public struct Language: Sendable, Equatable {
        public let code: String  // "de"
        public let name: String  // "german"

        /// Title-cased for the menu; whisper stores the names lowercase.
        public var title: String { name.prefix(1).uppercased() + name.dropFirst() }
    }

    public static let all: [Language] = (0...whisper_lang_max_id()).compactMap { id in
        guard let code = whisper_lang_str(id).map(String.init(cString:)),
              let name = whisper_lang_str_full(id).map(String.init(cString:))
        else { return nil }
        return Language(code: code, name: name)
    }

    /// The shortlist the menu shows first: everything Whisper transcribes at
    /// under ~10 % WER on FLEURS (Whisper paper, Table 13). Everything else is
    /// still selectable under "All languages…" — it is just honest about which
    /// ones are demo-quality.
    public static let common = ["ca", "de", "en", "es", "fi", "fr", "id", "it", "ja",
                                "ms", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk"]

    /// whisper's numeric id for a language code, or -1 for an unknown one.
    public static func id(of code: String) -> Int32 { whisper_lang_id(code) }

    public static func name(of code: String) -> String? {
        all.first { $0.code == code }?.title
    }

    public static func isKnown(_ code: String) -> Bool {
        all.contains { $0.code == code }
    }

    /// Picks the most likely language among `allowed` from a full probability
    /// table (whisper hands back one entry per language id). Falls back to
    /// `primary` when even the best allowed candidate is a coin flip —
    /// faster-whisper uses the same 0.5 default, and a confident wrong language
    /// produces confident garbage.
    public static func best(from probabilities: [Float], allowed: [String],
                            primary: String, threshold: Float = 0.5) -> String {
        let candidates = allowed.compactMap { code -> (String, Float)? in
            let id = Int(Self.id(of: code))
            guard id >= 0, id < probabilities.count else { return nil }
            return (code, probabilities[id])
        }
        guard let best = candidates.max(by: { $0.1 < $1.1 }) else { return primary }
        return best.1 >= threshold ? best.0 : primary
    }
}
