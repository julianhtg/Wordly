import Foundation

/// What the dictation path needs from a speech engine. One method — models,
/// language identification and warm-up all stay behind it.
public protocol SpeechEngine: AnyObject, Sendable {
    /// Shown in the menu and the log line.
    var name: String { get }
    /// Language codes this engine can transcribe; nil means no restriction.
    var supportedLanguages: Set<String>? { get }

    func transcribe(_ samples: [Float], languages: [String],
                    initialPrompt: String) async -> TranscriptResult
}

public enum EngineRouting {
    /// Parakeet is two orders of magnitude cheaper per clip, but it only knows
    /// its own ~30 languages and has no way to say "that wasn't one of mine" —
    /// handed Thai it would emit confident nonsense. So it gets the job only
    /// when every language the user selected is one it actually speaks, which
    /// also means "Auto over all 100" stays on Whisper by construction.
    public static func prefersFast(languages: [String], fast: Set<String>) -> Bool {
        !languages.isEmpty && languages.allSatisfy(fast.contains)
    }

    public static let fast = "parakeet"
    public static let general = "whisper"

    /// Which engine to load, before either exists. `preference` is "auto" or an
    /// engine name to force from the config/menu.
    public static func engineName(preference: String, languages: [String],
                                  fastLanguages: Set<String>) -> String {
        if preference == fast || preference == general { return preference }
        return prefersFast(languages: languages, fast: fastLanguages) ? fast : general
    }
}
