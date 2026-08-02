import FluidAudio
import Foundation

/// Parakeet TDT v3 on the Neural Engine, via FluidAudio. Roughly two orders of
/// magnitude cheaper than Whisper's encoder for a push-to-talk clip, with
/// punctuation and language identification built into the model — but it only
/// knows the languages in `supported`.
///
/// It does not report which language it decided on, so the result carries the
/// user's pinned language when there is one and nothing when there isn't.
public final class ParakeetEngine: SpeechEngine, @unchecked Sendable {
    public let name = "parakeet"
    public var supportedLanguages: Set<String>? { Self.supported }

    /// Taken from FluidAudio's own table so it cannot drift from the model.
    /// (Aliased because `FluidAudio.Language` doesn't resolve — the module also
    /// exports a type called `FluidAudio`, which shadows the module name.)
    private typealias ParakeetLanguage = Language
    public static let supported = Set(ParakeetLanguage.allCases.map(\.rawValue))

    private let manager: AsrManager

    private init(manager: AsrManager) {
        self.manager = manager
    }

    /// Downloads (first run) and loads the CoreML models. `progress` reports
    /// 0...100 while downloading.
    public static func load(progress: @escaping @Sendable (Int) -> Void) async throws
        -> ParakeetEngine {
        let models = try await AsrModels.downloadAndLoad(version: .v3) { update in
            progress(Int(update.fractionCompleted * 100))
        }
        return ParakeetEngine(manager: AsrManager(config: .default, models: models))
    }

    /// ponytail: `initialPrompt` is ignored — a transducer has no prompt to
    /// continue, so the user dictionary does not bias this engine. FluidAudio
    /// ships CTC word-spotting for exactly this (`CtcModels`), at the cost of
    /// another model download; wire it up if custom vocabulary starts mattering
    /// more than the second it would add to first launch.
    public func transcribe(_ samples: [Float], languages: [String],
                           initialPrompt: String) async -> TranscriptResult {
        // One language selected: tell the model, so it constrains its output to
        // that script. Several: let its own language ID decide.
        let hint = languages.count == 1 ? ParakeetLanguage(rawValue: languages[0]) : nil
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(samples, decoderState: &state,
                                                      language: hint)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            wordlyLog(String(format: "Wordly: parakeet %.1fs audio → %.0fms lang=%@",
                         Double(samples.count) / 16000, elapsed * 1000, hint?.rawValue ?? "auto"))
            return TranscriptResult(
                text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                language: hint?.rawValue ?? "", elapsed: elapsed)
        } catch {
            wordlyLog("Wordly: parakeet failed: \(error)")
            return .empty
        }
    }
}
