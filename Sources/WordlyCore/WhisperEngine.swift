import Foundation

/// whisper.cpp behind the engine protocol: every language, but the encoder
/// costs a fixed ~30 seconds of work per clip whatever you say.
///
/// `@unchecked Sendable` is honest here rather than lazy: `Transcriber` is
/// explicitly not thread-safe, and the serial queue below is what makes that
/// contract hold — nothing else touches it.
public final class WhisperEngine: SpeechEngine, @unchecked Sendable {
    public let name = "whisper"
    public var supportedLanguages: Set<String>? { nil }

    private let transcriber: Transcriber
    private let queue = DispatchQueue(label: "dev.wordly.whisper", qos: .userInitiated)

    public init(transcriber: Transcriber) {
        self.transcriber = transcriber
    }

    /// Loads the model and compiles the Metal kernels; nil if the file is
    /// unusable. Slow (seconds) — call it off the main thread.
    public static func load(modelPath: String) -> WhisperEngine? {
        guard let transcriber = Transcriber(modelPath: modelPath) else { return nil }
        transcriber.warmUp()
        return WhisperEngine(transcriber: transcriber)
    }

    public func transcribe(_ samples: [Float], languages: [String],
                           initialPrompt: String) async -> TranscriptResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.transcriber.transcribe(
                    samples, languages: languages, initialPrompt: initialPrompt))
            }
        }
    }
}
