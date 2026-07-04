import AVFoundation
import AppKit

/// Captures microphone audio as 16 kHz mono Float32 (what whisper.cpp wants),
/// accumulated in RAM. Dictation is seconds to minutes — no temp files.
public final class Recorder {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let lock = NSLock()
    public private(set) var isRecording = false

    public init() {}

    public func start() {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

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
            guard status != .error, let channel = converted.floatChannelData else { return }
            self.lock.lock()
            self.samples.append(contentsOf:
                UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength)))
            self.lock.unlock()
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
        let result = discard ? [] : samples
        samples = []
        lock.unlock()
        return result
    }
}
