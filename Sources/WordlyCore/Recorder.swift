import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio

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

    /// UID of the microphone to record from; nil = system default. Applied on
    /// the next start(). ponytail: switching mid-session relies on the engine
    /// being stopped between recordings (it always is); relaunch if a hot-swap
    /// ever misbehaves.
    public var inputDeviceUID: String?

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    // Auto-gain state for the level meter: a slowly-decaying peak the current
    // level is normalized against, so the bars fill their range for loud and
    // quiet mics alike. Touched only on the audio thread (single writer).
    private var levelPeak: Float = 0.01
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
        levelPeak = 0.01  // recalibrate auto-gain each session (before the tap runs)

        let input = engine.inputNode
        if let uid = inputDeviceUID, let deviceID = AudioDevices.deviceID(forUID: uid),
           let audioUnit = input.audioUnit {
            var dev = deviceID
            AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &dev,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16000, channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            wordlyLog("Recorder: no usable input device")
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
                let rms = (sumSquares / Float(frames)).squareRoot()
                // Auto-gain: rise instantly to new peaks, decay so a loud burst
                // doesn't desensitize the meter for long, and normalize against
                // that peak (floored so background noise reads as silence). A low
                // gate keeps the resting line flat; a sqrt curve makes moderate
                // speech fill the bars instead of needing a shout.
                self.levelPeak = max(rms, self.levelPeak * 0.97)
                let norm = rms / max(self.levelPeak, 0.01)
                let gate: Float = 0.06
                let level = norm <= gate ? 0 : min(1, ((norm - gate) / (1 - gate)).squareRoot())
                DispatchQueue.main.async { onLevel(level) }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            wordlyLog("Recorder: engine start failed: \(error)")
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
