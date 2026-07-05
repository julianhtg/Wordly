import AVFoundation
import AppKit

/// Captures microphone audio as 16 kHz mono Float32 (what whisper.cpp wants),
/// accumulated in RAM. Dictation is seconds to minutes — no temp files.
/// Not thread-safe: call start()/stop() from one thread (the main thread —
/// AppDelegate's single-flight gate serializes them). Only the tap callback
/// runs on the audio thread, synchronized via `lock` + `generation`.
public final class Recorder {
    /// Live input level (0...1, RMS) while recording, delivered on the main
    /// thread for the floating indicator. Cosmetic — stale values are harmless,
    /// so it is not generation-guarded.
    public var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let lock = NSLock()
    // Bumped each start(); a straggling tap callback from a previous session
    // (removeTap doesn't synchronously halt in-flight callbacks) sees a stale
    // generation and drops its audio instead of polluting the new recording.
    private var generation = 0
    public private(set) var isRecording = false

    public init() {}

    public func start() {
        guard !isRecording else { return }
        lock.lock()
        generation += 1
        let myGeneration = generation
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16000, channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            NSLog("Recorder: no usable input device")
            return
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                   frameCapacity: capacity) else { return }
            var fed = false
            let status = converter.convert(to: converted, error: nil) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            // Failure paths above stay silent on purpose: no NSLog on the
            // real-time audio thread (priority-inversion risk).
            guard status != .error, let channel = converted.floatChannelData else { return }
            let frames = Int(converted.frameLength)
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.generation == myGeneration else { return }
            self.samples.append(contentsOf:
                UnsafeBufferPointer(start: channel[0], count: frames))

            if let onLevel = self.onLevel, frames > 0 {
                var sumSquares: Float = 0
                for i in 0..<frames { sumSquares += channel[0][i] * channel[0][i] }
                let level = min(1, (sumSquares / Float(frames)).squareRoot() * 6)
                DispatchQueue.main.async { onLevel(level) }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            NSLog("Recorder: engine start failed: \(error)")
            return
        }
        isRecording = true
        NSSound(named: "Pop")?.play()
    }

    /// Stops capture. `discard: true` drops the audio silently (tap/cancel).
    @discardableResult
    public func stop(discard: Bool = false) -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        if !discard { NSSound(named: "Bottle")?.play() }
        lock.lock()
        defer { lock.unlock() }
        let result = discard ? [] : samples
        samples = []
        return result
    }
}
