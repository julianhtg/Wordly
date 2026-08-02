import Foundation
import whisper

/// The knobs that decide how long a transcription takes. The defaults are what
/// the app ships; each one below records what measuring it actually showed,
/// including the two changes that looked obvious and were rejected.
public struct TranscribeOptions: Sendable {
    /// "auto" (whisper detects, which costs a whole extra encoder pass) or a
    /// two-letter code.
    public var language = "auto"
    public var initialPrompt = ""
    /// Encoder context in frames. 0 = whisper's full 1500, i.e. 30 seconds of
    /// encoder work no matter how short the clip is.
    ///
    /// Shortening this to fit the clip is the obvious win and it does not work:
    /// measured on this corpus it cut the time 2-3× but took word error from
    /// 10.4 % to 21 % (768 frames), 39 % (512) and 362 % (192 — runaway
    /// hallucination). Identical damage with flash attention on and off, so it
    /// is the truncated context itself, not a kernel bug. Left settable for the
    /// benchmark; the app keeps 0.
    public var audioContext: Int32 = 0
    /// > 0 re-decodes at rising temperatures when a pass scores badly — up to
    /// six passes for one clip, which is the shape of an irregular slow
    /// dictation. Left at whisper's default: clean speech never triggers it (the
    /// bench corpus recorded zero fallbacks), so there was nothing to measure a
    /// change against. A slow run now logs its own fallback count instead.
    public var temperatureInc: Float = 0.2
    /// whisper's own default, min(4, cores), rather than the cores-minus-two
    /// this used to ship. Measured on a 4P+6E M4 the two are the same speed
    /// (4796 ms vs 4832 ms median) — the work is on the GPU, so the thread count
    /// barely matters. Kept at the performance-core count because it does the
    /// same job without spinning up six efficiency cores on a fanless laptop.
    public var threads = Int32(performanceCoreCount)

    public init() {}
}

/// Physical performance cores (4 on an M4, 6 on an M4 Pro …), falling back to a
/// conservative 4 on anything that doesn't report the modern topology.
public let performanceCoreCount: Int = {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0) == 0, value > 0 else {
        return 4
    }
    return Int(value)
}()

public struct TranscriptResult: Sendable {
    public let text: String
    /// The language whisper actually used — detected or the one we forced.
    public let language: String
    public let elapsed: TimeInterval

    public static let empty = TranscriptResult(text: "", language: "", elapsed: 0)
}

/// In-process whisper.cpp. Model loads once (seconds) and stays in RAM;
/// transcription runs Metal-accelerated. Not thread-safe — callers serialize
/// (AppDelegate is single-flight by design). transcribe() blocks for seconds,
/// so call it from a background queue — and this instance must outlive any
/// in-flight call: deinit runs whisper_free, so releasing/replacing the
/// holding property mid-transcription is a use-after-free, not a data race.
public final class Transcriber {
    private let ctx: OpaquePointer

    /// whisper logs to stderr, which never reaches the unified log — so its
    /// most useful lines (Core ML fallback, "auto-detected language: de",
    /// timings) were invisible. Bridge them into the same `Wordly:` stream
    /// everything else uses. Runs once; the callback captures nothing so it
    /// converts to a C function pointer.
    private static let bridgeLogs: Void = {
        whisper_log_set({ _, text, _ in
            guard let text else { return }
            let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { wordlyLog("Wordly/whisper: \(line)") }
        }, nil)
    }()

    public let flashAttention: Bool

    public init?(modelPath: String, flashAttention: Bool = true) {
        _ = Self.bridgeLogs
        func makeContext(flashAttn: Bool) -> OpaquePointer? {
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = flashAttn  // faster decode; not every build accepts it
            return whisper_init_from_file_with_params(modelPath, params)
        }
        // Prefer the requested setting, but never let it be the reason the model
        // won't load — fall back rather than leaving the app permanently dead.
        guard let ctx = makeContext(flashAttn: flashAttention)
                ?? makeContext(flashAttn: !flashAttention) else {
            return nil
        }
        self.ctx = ctx
        self.flashAttention = flashAttention
    }

    deinit { whisper_free(ctx) }

    /// Runs one throwaway transcription on silence to compile the Metal
    /// kernels, so the user's first real dictation isn't the slow one. Call
    /// once on a background queue after init; obeys the same serialization
    /// contract as transcribe().
    public func warmUp() {
        var options = TranscribeOptions()
        options.language = "en"
        _ = transcribe([Float](repeating: 0, count: 16000), options: options)
    }

    /// Transcribes in the user's languages. One language pins it — that skips a
    /// whole encoder pass, which is most of the wait. Several runs whisper's own
    /// detector and clamps the answer to the list, which costs exactly what
    /// `language = "auto"` costs anyway (whisper detects with a full extra
    /// encode internally), so the accuracy is free. Empty = whatever whisper
    /// picks out of all 100.
    public func transcribe(_ samples: [Float], languages: [String],
                           initialPrompt: String) -> TranscriptResult {
        // Before resolving anything: language detection is a full encoder pass,
        // and an accidental key tap doesn't deserve one.
        guard samples.count > 3200 else { return .empty }  // <0.2 s: nothing to hear
        var options = TranscribeOptions()
        options.initialPrompt = initialPrompt
        options.language = resolveLanguage(samples, allowed: languages)
        return transcribe(samples, options: options)
    }

    /// "auto" when the caller allows every language; otherwise a concrete code.
    private func resolveLanguage(_ samples: [Float], allowed: [String]) -> String {
        guard allowed.count > 1 else { return allowed.first ?? "auto" }
        let primary = allowed[0]
        var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        let threads = TranscribeOptions().threads
        // Recomputing the mel in whisper_full afterwards costs single-digit ms
        // (measured), so there is no point reusing state to skip it.
        let detected = samples.withUnsafeBufferPointer { buffer -> Int32 in
            guard whisper_pcm_to_mel(ctx, buffer.baseAddress, Int32(buffer.count), threads) == 0
            else { return -1 }
            return whisper_lang_auto_detect(ctx, 0, threads, &probabilities)
        }
        guard detected >= 0 else { return primary }
        return Languages.best(from: probabilities, allowed: allowed, primary: primary)
    }

    /// Returns an empty transcript for silence or failure.
    public func transcribe(_ samples: [Float], options: TranscribeOptions) -> TranscriptResult {
        guard samples.count > 3200 else { return .empty }  // <0.2 s: nothing to hear

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.no_timestamps = true
        params.suppress_blank = true
        params.n_threads = options.threads
        params.audio_ctx = options.audioContext
        params.temperature_inc = options.temperatureInc

        let languageC = strdup(options.language)
        let promptC = options.initialPrompt.isEmpty ? nil : strdup(options.initialPrompt)
        defer {
            free(languageC)
            promptC.map { free($0) }
        }
        params.language = UnsafePointer(languageC)
        params.initial_prompt = promptC.map { UnsafePointer($0) }

        whisper_reset_timings(ctx)
        let start = DispatchTime.now().uptimeNanoseconds
        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        guard status == 0 else { return .empty }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            text += String(cString: whisper_full_get_segment_text(ctx, i))
        }

        let language = whisper_lang_str(whisper_full_lang_id(ctx)).map(String.init(cString:)) ?? ""
        let seconds = Double(samples.count) / 16000
        wordlyLog(String(format: "Wordly: whisper %.1fs audio → %.0fms lang=%@ ctx=%d "
                     + "threads=%d temp_inc=%.2f",
                     seconds, elapsed * 1000, language, options.audioContext,
                     options.threads, options.temperatureInc))
        // A slow run explains itself: whisper's own breakdown says whether the
        // time went into the encoder or into temperature-fallback re-decodes.
        // ponytail: threshold, not a debug flag — nothing to configure, and the
        // log stays quiet on the runs nobody complains about.
        if elapsed > 1.5 { whisper_print_timings(ctx) }

        return TranscriptResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                language: language, elapsed: elapsed)
    }
}
