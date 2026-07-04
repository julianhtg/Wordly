import Foundation
import whisper

/// In-process whisper.cpp. Model loads once (seconds) and stays in RAM;
/// transcription runs Metal-accelerated. Not thread-safe — callers serialize
/// (AppDelegate is single-flight by design).
public final class Transcriber {
    private let ctx: OpaquePointer

    public init?(modelPath: String) {
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            return nil
        }
        self.ctx = ctx
    }

    deinit { whisper_free(ctx) }

    /// `language`: "auto" | "de" | "en". Returns "" for silence or failure.
    public func transcribe(_ samples: [Float], language: String,
                           initialPrompt: String) -> String {
        guard samples.count > 3200 else { return "" }  // <0.2 s: nothing to hear

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.no_timestamps = true
        params.suppress_blank = true
        params.n_threads = Int32(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))

        let languageC = strdup(language)
        let promptC = initialPrompt.isEmpty ? nil : strdup(initialPrompt)
        defer {
            free(languageC)
            promptC.map { free($0) }
        }
        params.language = UnsafePointer(languageC)
        params.initial_prompt = promptC.map { UnsafePointer($0) }

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
        }
        guard status == 0 else { return "" }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            text += String(cString: whisper_full_get_segment_text(ctx, i))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
