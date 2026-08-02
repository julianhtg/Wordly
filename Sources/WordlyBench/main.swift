import AVFoundation
import Foundation
import WordlyCore

// Latency/accuracy harness for the dictation path. Every knob in the pipeline
// is a guess until this prints a number.
//
//   swift run -c release WordlyBench [corpus-dir] [--repeat N] [--model PATH] [--verbose]
//
// Corpus layout: <lang>-<name>.wav next to <lang>-<name>.txt holding the words
// that were actually spoken. scripts/make-bench-audio.sh generates a synthetic
// one; real recordings dropped in the same folder count the same and matter more.

// MARK: - Arguments

var corpusDir = "bench/audio"
var repeats = 3
var modelPaths: [String] = []
var verbose = false
var includeRejected = false

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--repeat": repeats = Int(args.removeFirst()) ?? repeats
    case "--model": modelPaths.append(args.removeFirst())
    case "--verbose": verbose = true
    case "--all": includeRejected = true
    default: corpusDir = arg
    }
}
if modelPaths.isEmpty { modelPaths = [Config.load().modelURL.path] }

// MARK: - Corpus

struct Clip {
    let name: String
    let language: String
    let samples: [Float]
    let expected: String
    var seconds: Double { Double(samples.count) / 16000 }
}

/// Reads any audio file as the 16 kHz mono Float32 whisper wants — the same
/// format Recorder produces, so the bench sees what the app sees.
func loadSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                     channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: file.processingFormat, to: target),
          let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                       frameCapacity: AVAudioFrameCount(file.length))
    else { throw CocoaError(.fileReadCorruptFile) }
    try file.read(into: input)

    let ratio = target.sampleRate / file.processingFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    var fed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if fed { status.pointee = .noDataNow; return nil }
        fed = true
        status.pointee = .haveData
        return input
    }
    if let error { throw error }
    guard let channel = output.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
    return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
}

func loadCorpus(_ directory: String) -> [Clip] {
    let url = URL(fileURLWithPath: directory)
    let files = (try? FileManager.default.contentsOfDirectory(at: url,
                                                              includingPropertiesForKeys: nil)) ?? []
    return files.filter { ["wav", "aiff", "aif", "m4a", "mp3"].contains($0.pathExtension) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { file in
            let name = file.deletingPathExtension().lastPathComponent
            guard let samples = try? loadSamples(file) else {
                print("skipped \(name): could not read audio")
                return nil
            }
            let transcript = file.deletingPathExtension().appendingPathExtension("txt")
            let expected = (try? String(contentsOf: transcript, encoding: .utf8)) ?? ""
            return Clip(name: name,
                        language: String(name.prefix(while: { $0 != "-" })),
                        samples: samples,
                        expected: expected.trimmingCharacters(in: .whitespacesAndNewlines))
        }
}

// MARK: - Word error rate

func words(_ text: String) -> [String] {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

/// Levenshtein over words, as a percentage of the reference length.
func wordErrorRate(reference: String, hypothesis: String) -> Double? {
    let ref = words(reference), hyp = words(hypothesis)
    guard !ref.isEmpty else { return nil }  // no ground truth on file
    var previous = Array(0...hyp.count)
    var current = [Int](repeating: 0, count: hyp.count + 1)
    for i in 1...ref.count {
        current[0] = i
        for j in stride(from: 1, through: hyp.count, by: 1) {  // empty hypothesis: no inner pass
            let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        }
        swap(&previous, &current)
    }
    return Double(previous[hyp.count]) / Double(ref.count) * 100
}

// MARK: - Variants

/// Each row changes ONE thing against the shared base, so a bad row can't be
/// blamed on the row above it (the first ladder-shaped attempt at this table
/// hid an audio_ctx failure behind two other knobs).
struct Variant {
    let name: String
    var flashAttention = true
    let options: (Clip) -> TranscribeOptions
}

let performanceCores = Int32(performanceCoreCount)
/// What the app shipped before this round of measuring: cores minus two.
let currentThreads = Int32(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))

/// Scales whisper's encoder context to the clip instead of always paying for a
/// full 30 s window. Kept here rather than in the app because the measurement
/// rejected it — see the note on TranscribeOptions.audioContext.
enum AudioContext {
    static let full: Int32 = 1500  // WHISPER_N_AUDIO_CTX

    static func frames(seconds: Double, margin: Double = 1.5, floor: Int32 = 192) -> Int32 {
        guard seconds > 0 else { return full }
        let scaled = ((seconds + margin) / 30 * Double(full) / 64).rounded(.up) * 64
        return min(full, max(floor, Int32(scaled)))
    }
}

/// pinned language + performance-core threads: both are free wins the first run
/// proved, so every experiment below starts from there.
func base(_ clip: Clip) -> TranscribeOptions {
    var options = TranscribeOptions()
    options.threads = performanceCores
    options.language = clip.language
    return options
}

func withContext(_ floor: Int32) -> (Clip) -> TranscribeOptions {
    { clip in
        var options = base(clip)
        options.audioContext = AudioContext.frames(seconds: clip.seconds, floor: floor)
        return options
    }
}

let variants: [Variant] = [
    Variant(name: "shipped (auto, 8 threads)") { _ in
        var options = TranscribeOptions()
        options.threads = currentThreads
        return options
    },
    Variant(name: "auto language, 4 threads") { clip in
        var options = base(clip)
        options.language = "auto"
        return options
    },
    Variant(name: "pinned language, P-cores", options: base),
]

/// The two knobs that were measured and rejected. Behind --all because they
/// double the runtime to re-prove a negative: shortening the encoder context
/// wrecks accuracy at every floor tried (flash attention on or off), and
/// disabling the temperature fallback changes nothing on speech this clean.
let rejectedVariants: [Variant] = [
    Variant(name: "rejected: audio_ctx≥768", options: withContext(768)),
    Variant(name: "rejected: no temp fallback") { clip in
        var options = base(clip)
        options.temperatureInc = 0
        return options
    },
]

// MARK: - Run

let clips = loadCorpus(corpusDir)
guard !clips.isEmpty else {
    print("no audio in \(corpusDir) — run scripts/make-bench-audio.sh first")
    exit(1)
}
let totalSeconds = clips.reduce(0) { $0 + $1.seconds }
print("corpus: \(clips.count) clips, \(String(format: "%.1f", totalSeconds))s total, "
      + "languages \(Set(clips.map(\.language)).sorted().joined(separator: " "))")
print("cores: \(performanceCores) performance, comparing against the shipped \(currentThreads)\n")

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[index]
}

for modelPath in modelPaths {
    let model = URL(fileURLWithPath: modelPath).lastPathComponent
    guard FileManager.default.fileExists(atPath: modelPath) else {
        print("model missing: \(modelPath)")
        continue
    }
    print("## \(model)\n")
    print("| variant | median | p95 | ×RT | WER | wrong lang |")
    print("|---|---|---|---|---|---|")

    // Flash attention is fixed at context creation, so group by it — and let
    // each context go out of scope before the next one allocates a second
    // copy of the model.
    let selected = variants + (includeRejected ? rejectedVariants : [])
    for flashAttention in [true, false] {
        let group = selected.filter { $0.flashAttention == flashAttention }
        guard !group.isEmpty,
              let transcriber = Transcriber(modelPath: modelPath,
                                            flashAttention: flashAttention) else { continue }
        transcriber.warmUp()

        for variant in group {
            var times: [Double] = []
            var errorRates: [Double] = []
            var wrongLanguage = 0
            for clip in clips {
                let options = variant.options(clip)
                for _ in 0..<repeats {
                    let result = transcriber.transcribe(clip.samples, options: options)
                    times.append(result.elapsed * 1000)
                    if result.language != clip.language { wrongLanguage += 1 }
                    if let wer = wordErrorRate(reference: clip.expected, hypothesis: result.text) {
                        errorRates.append(wer)
                    }
                    if verbose {
                        print("    \(clip.name) [\(result.language)] "
                              + "\(String(format: "%.0f", result.elapsed * 1000))ms: \(result.text)")
                    }
                }
            }
            let median = percentile(times, 0.5)
            let realtime = totalSeconds * 1000 * Double(repeats) / max(times.reduce(0, +), 1)
            let wer = errorRates.isEmpty
                ? "—"
                : String(format: "%.1f%%", errorRates.reduce(0, +) / Double(errorRates.count))
            print(String(format: "| %@ | %.0f ms | %.0f ms | %.1f× | %@ | %d |",
                         variant.name, median, percentile(times, 0.95), realtime,
                         wer, wrongLanguage))
        }
    }
    print("")
}

// MARK: - Parakeet

// The other engine on the same clips. Only the languages it claims — handing it
// Thai would measure nothing except that it cannot do Thai.
let parakeetClips = clips.filter { ParakeetEngine.supported.contains($0.language) }
if !parakeetClips.isEmpty {
    print("## parakeet-tdt-v3\n")
    // FluidAudio reports progress per chunk, so only print when it moves a
    // decile. ponytail: racing on this counter costs a duplicate log line.
    nonisolated(unsafe) var lastDecile = -1
    let engine = try await ParakeetEngine.load { percent in
        guard percent / 10 > lastDecile else { return }
        lastDecile = percent / 10
        print("  downloading models… \(percent)%")
    }
    print("| clip | median | WER | transcript |")
    print("|---|---|---|---|")
    var all: [Double] = []
    for clip in parakeetClips {
        var times: [Double] = []
        var text = ""
        for _ in 0..<repeats {
            let result = await engine.transcribe(clip.samples, languages: [clip.language],
                                                 initialPrompt: "")
            times.append(result.elapsed * 1000)
            text = result.text
        }
        all.append(contentsOf: times)
        let wer = wordErrorRate(reference: clip.expected, hypothesis: text)
            .map { String(format: "%.1f%%", $0) } ?? "—"
        print(String(format: "| %@ | %.0f ms | %@ | %@ |", clip.name, percentile(times, 0.5),
                     wer, text.prefix(60).replacingOccurrences(of: "|", with: "/")))
    }
    print(String(format: "\nparakeet overall: median %.0f ms, p95 %.0f ms",
                 percentile(all, 0.5), percentile(all, 0.95)))
}
