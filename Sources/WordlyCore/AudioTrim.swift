import Foundation

/// Trims leading/trailing near-silence from a 16 kHz mono buffer so whisper
/// decodes only the speech. Holding the hotkey a beat before/after talking is
/// normal, and every trimmed second is decode time saved.
public enum AudioTrim {
    /// `threshold`: RMS below this (per 10 ms window) counts as silence.
    /// `padding`: seconds of audio kept around the detected speech so onsets
    /// aren't clipped. Returns the input unchanged if nothing crosses the
    /// threshold (better a slow transcript than a destroyed one).
    public static func trim(_ samples: [Float], sampleRate: Int = 16000,
                            threshold: Float = 0.01, padding: TimeInterval = 0.1) -> [Float] {
        let window = max(1, sampleRate / 100)             // 10 ms
        guard samples.count > window else { return samples }

        var firstLoud = -1
        var lastLoud = -1
        var i = 0
        while i < samples.count {
            let end = min(i + window, samples.count)
            var sumSquares: Float = 0
            for j in i..<end { sumSquares += samples[j] * samples[j] }
            let rms = (sumSquares / Float(end - i)).squareRoot()
            if rms >= threshold {
                if firstLoud < 0 { firstLoud = i }
                lastLoud = end
            }
            i += window
        }

        guard firstLoud >= 0 else { return samples }       // all silence — keep it
        let pad = Int(padding * Double(sampleRate))
        let start = max(0, firstLoud - pad)
        let stop = min(samples.count, lastLoud + pad)
        return Array(samples[start..<stop])
    }
}
